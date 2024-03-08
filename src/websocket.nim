import std/bitops
import std/base64
import std/random
import std/asyncnet
import std/asyncdispatch
import std/asynchttpserver
import std/httpclient
import std/uri
import pkg/checksums/sha1
import utils


type
  WebSocketRecvError* = object of IOError
  WebSocketSendError* = object of IOError


template newWebSocketRecvError*: untyped =
  newException(WebSocketRecvError, "recv failed")


template newWebSocketSendError*: untyped =
  newException(WebSocketSendError, "send failed")


const magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


type
  WebSocketPayloadType* = enum
    Text
    Binary
    Close
    Ping
    Pong
    Invalid

  WebSocketPayload* = ref object
    case kind*: WebSocketPayloadType
    of Text:
      str*: string
    of Binary:
      bytes*: seq[byte]
    of Close:
      code*: uint16
    of Ping:
      pingBytes*: seq[byte]
    of Pong:
      pongBytes*: seq[byte]
    of Invalid:
      discard

  WebSocketPayloadBytes* = ref object
    kind: WebSocketPayloadType
    data: seq[byte]

  WebSocketFrameHeader* = object
    fin*: byte
    opcode*: byte
    isMasked*: byte
    payloadLen*: uint64

  WebSocketRole* = enum
    Server
    Client

  WebSocketConn* = ref object
    socket: AsyncSocket
    role: WebSocketRole

    # recv data
    isRecvInitialFrame = true
    isRecvFragmented = false
    initialFrameOpcode: byte = 0
    recvPayloadBuf: seq[byte] = @[]


proc toByte*(payloadType: WebSocketPayloadType): byte =
  case payloadType
  of Text: 0x1
  of Binary: 0x2
  of Close: 0x8
  of Ping: 0x9
  of Pong: 0xA
  else: 0x0


proc isFin*(frameHeader: WebSocketFrameHeader): bool =
  frameHeader.fin == 1


proc serialize*(frameHeader: WebSocketFrameHeader, payloadLen: uint64): seq[byte] =
  result = @[0'u8, 0'u8]
  result[0] = result[0].setMasked(frameHeader.fin shl 7)
  result[0] = result[0].setMasked(frameHeader.opcode)
  result[1] = result[1].setMasked(frameHeader.isMasked shl 7)
  if payloadLen < 126:
    result[1] = result[1].setMasked(payloadLen.uint8)
  elif payloadLen <= uint16.high():
    result[1] = result[1].setMasked(126'u8)
    result &= array[2, uint8].default()
    payloadLen.uint16().toBigEndian(result[2].addr())
  else:
    result[1] = result[1].setMasked(127'u8)
    result &= array[8, uint8].default()
    payloadLen.toBigEndian(result[2].addr())


proc newWebSocketServer*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, role: Server)


proc newWebSocketClient*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, role: Client)


proc isClosed*(conn: WebSocketConn): bool =
  conn.socket.isClosed()


proc isServer*(conn: WebSocketConn): bool =
  conn.role == Server


proc isClient*(conn: WebSocketConn): bool =
  conn.role == Client


proc isValidMask*(conn: WebSocketConn, frameHeader: WebSocketFrameHeader): bool =
  ## The server MUST close the connection upon receiving a
  ## frame that is not masked.  In this case, a server MAY send a Close
  ## frame with a status code of 1002 (protocol error) as defined in
  ## Section 7.4.1.  A server MUST NOT mask any frames that it sends to
  ## the client.  A client MUST close a connection if it detects a masked
  ## frame.  In this case, it MAY use the status code 1002 (protocol
  ## error) as defined in Section 7.4.1.
  ## <https://datatracker.ietf.org/doc/html/rfc6455#section-5.1>
  conn.isServer() and frameHeader.isMasked == 1 or
  conn.isClient() and frameHeader.isMasked != 1


proc resetState*(conn: WebSocketConn) =
  conn.isRecvInitialFrame = true
  conn.isRecvFragmented = false
  conn.initialFrameOpcode = 0
  conn.recvPayloadBuf = @[]


proc deinit*(conn: WebSocketConn) =
  ## Close the tcp socket.
  conn.resetState()
  if not conn.socket.isClosed():
    conn.socket.close()


proc connect*(url: Uri | string, protocol: string): Future[WebSocketConn] {.async.} =
  randomize()
  var client = newAsyncHttpClient()

  try:
    var rndNums: array[16, uint8]
    for n in rndNums.mitems():
      n = rand(0'u8 .. uint8.high())

    let webSocketKey = rndNums.encode()
    let acceptKey = base64.encode(cast[array[20, uint8]](secureHash(webSocketKey & magicString)))

    let headers = newHttpHeaders({
      "Upgrade": "websocket",
      "Connection": "Upgrade",
      "Sec-WebSocket-Key": webSocketKey,
      "Sec-WebSocket-Version": "13",
    })
    if protocol != "":
      headers.add("Sec-WebSocket-Protocol", protocol)

    let resp = await client.request(url, httpMethod = HttpGet, headers = headers, body = "")

    # TODO: more checks
    # check response
    let serverAcceptKey = resp.headers.getOrDefault("Sec-WebSocket-Accept")
    if serverAcceptKey == acceptKey:
      return newWebSocketClient(client.getSocket())
    else:
      return nil

  except Defect:
    return nil

  except CatchableError:
    return nil


proc handshake*(req: Request, protocol: string): Future[bool] {.async.} =
  ## Try handshake.
  ## Return false if handshake fails.
  let
    webSocketKey = req.headers.getOrDefault("Sec-WebSocket-Key")
    webSocketVersion = req.headers.getOrDefault("Sec-WebSocket-Version")
    webSocketProtocol = req.headers.getOrDefault("Sec-WebSocket-Protocol")

  if webSocketKey == "" or webSocketVersion != "13":
    await req.respond(Http400, "", newHttpHeaders())
    return false

  if webSocketProtocol != protocol:
    await req.respond(Http400, "", newHttpHeaders())
    return false

  let acceptKey = base64.encode(cast[array[20, uint8]](secureHash(webSocketKey & magicString)))

  await req.respond(Http101, "", newHttpHeaders({
    "Upgrade": "websocket",
    "Connection": "Upgrade",
    "Sec-WebSocket-Accept": acceptKey,
  }))
  return true


proc webSocketAccept*(req: Request, protocol: string): Future[WebSocketConn] {.async.} =
  ## Try handshake and return WebSocketConn.
  ## Return nil if handshake fails.
  if await handshake(req, protocol):
    randomize()
    newWebSocketServer(req.client)
  else:
    nil


proc recvBytes(socket: AsyncSocket, size: static int): Future[array[size, byte]] {.async.} =
  let readBytes = await socket.recvInto(result[0].addr(), size)
  if readBytes < size:
    raise newWebSocketRecvError()


proc recvPayloadLen(socket: AsyncSocket, payloadLen: uint64): Future[uint64] {.async.} =
  ## <https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#decoding_payload_length>
  result = payloadLen
  case result:
  of 126:
    let buf = await socket.recvBytes(2)
    result = fromBigEndian[uint16](buf[0].addr())
  of 127:
    let buf = await socket.recvBytes(4)
    result = fromBigEndian[uint64](buf[0].addr())
  else:
    discard
  result


proc recvMaskingKey(socket: AsyncSocket): Future[array[4, byte]] =
  socket.recvBytes(4)


template recvPayload(socket: AsyncSocket, payloadLen: uint64, payload: var seq[byte]) =
  if payloadLen > 0:
    let readBytes = await socket.recvInto(payload[0].addr(), payloadLen.int)
    if readBytes.uint64 < payloadLen:
      raise newWebSocketRecvError()
    payload.setLen(readBytes)


proc maskPayload(payload: var openArray[byte]): array[4, byte] =
  ## <https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data>
  let maskingKey = rand(0'u32 .. uint32.high())
  copyMem(result[0].addr(), maskingKey.addr(), sizeof(maskingKey))
  for i in 0 ..< payload.len():
    payload[i] = payload[i] xor result[i mod 4]


proc maskPayload(payload: var string): array[4, byte] =
  ## <https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data>
  maskPayload(payload.toOpenArrayByte(0, payload.high()))


template unmaskPayload(maskingKey: array[4, byte], payload: var openArray[byte]) =
  ## <https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data>
  for i in 0 ..< payload.len():
    payload[i] = payload[i] xor maskingKey[i mod 4]


proc recvFrameHeader*(conn: WebSocketConn): Future[WebSocketFrameHeader] {.async.} =
  ## Recive frame header.
  ## Can raise WebSocketRecvError.
  let buf = await conn.socket.recvBytes(2)
  WebSocketFrameHeader(
    fin: buf[0].bitsliced(7 .. 7),
    opcode: buf[0].bitsliced(0 .. 3),
    isMasked: buf[1].bitsliced(7 .. 7),
    payloadLen: await conn.socket.recvPayloadLen(buf[1].bitsliced(0 .. 6)),
  )


proc recvFramePayload*(conn: WebSocketConn, frameHeader: WebSocketFrameHeader): Future[WebSocketPayload] {.async.} =
  ## Recive frame payload and decode if masked.
  ## Can raise WebSocketRecvError.
  let
    fin = frameHeader.fin
    opcode = frameHeader.opcode
    isMasked = frameHeader.isMasked
    payloadLen = frameHeader.payloadLen

  # reset if expecting a continuation frame but it is not a continuation frame
  if not conn.isRecvInitialFrame and fin == 1 and opcode != 0:
    conn.resetState()

  if conn.isRecvInitialFrame:
    conn.isRecvInitialFrame = false
    conn.initialFrameOpcode = opcode
    if fin == 0:
      conn.isRecvFragmented = true

  # resize payload buffer
  conn.recvPayloadBuf.setLen(payloadLen)

  if isMasked == 1:
    # recv masked payload
    let maskingKey = await conn.socket.recvMaskingKey()
    conn.socket.recvPayload(payloadLen, conn.recvPayloadBuf)
    unmaskPayload(maskingKey, conn.recvPayloadBuf)
  else:
    # recv unmasked payload
    conn.socket.recvPayload(payloadLen, conn.recvPayloadBuf)

  # return fragmented payload
  if conn.isRecvFragmented:
    defer:
      if fin == 1:
        conn.resetState()
    return case conn.initialFrameOpcode:
      of 0x1: WebSocketPayload(kind: Text, str: stringFromBytes(conn.recvPayloadBuf))
      of 0x2: WebSocketPayload(kind: Binary, bytes: conn.recvPayloadBuf)
      else: WebSocketPayload(kind: Invalid)

  # return single payload
  case opcode:
  of 0x1: WebSocketPayload(kind: Text, str: stringFromBytes(conn.recvPayloadBuf))
  of 0x2: WebSocketPayload(kind: Binary, bytes: conn.recvPayloadBuf)
  of 0x8: WebSocketPayload(kind: Close, code: fromBigEndian[uint16](conn.recvPayloadBuf[0].addr()))
  of 0x9: WebSocketPayload(kind: Ping, pingBytes: conn.recvPayloadBuf)
  of 0xA: WebSocketPayload(kind: Pong, pongBytes: conn.recvPayloadBuf)
  else: WebSocketPayload(kind: Invalid)


template recvPayloadSingle*(conn: WebSocketConn, frameHeader: WebSocketFrameHeader, body: untyped) =
  if not conn.isClosed():
    if frameHeader.fin == 1:
      let payload {.inject.} = await conn.recvFramePayload(frameHeader)
      body


template recvPayloadFragmented*(conn: WebSocketConn, frameHeader: WebSocketFrameHeader, body: untyped) =
  if not conn.isClosed():
    var curFrameHeader = frameHeader
    if curFrameHeader.fin == 0:
      var compeleted {.inject.} = false
      while compeleted:
        if curFrameHeader.fin == 1:
          compeleted = true
        let payload {.inject.} = await conn.recvFramePayload(curFrameHeader)
        body
        if not compeleted:
          curFrameHeader = await conn.recvFrameHeader()


proc serializeSingle*(conn: WebSocketConn, payload: WebSocketPayload): WebSocketPayloadBytes =
  WebSocketPayloadBytes(
    kind: payload.kind,
    data: block:
      var data: seq[byte]
      let frameHeader = WebSocketFrameHeader(
        fin: 1,
        opcode: payload.kind.toByte(),
        isMasked: if conn.isServer(): 0 else: 1,
        payloadLen: 0,
      )
      case payload.kind
      of Text:
        data &= frameHeader.serialize(payload.str.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.str)
        data &= payload.str.toOpenArrayByte(0, payload.str.high())
      of Binary:
        data &= frameHeader.serialize(payload.bytes.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.bytes)
        data &= payload.bytes
      of Close:
        data &= frameHeader.serialize(2.uint64)
        var codeBuf: array[2, uint8]
        payload.code.toBigEndian(codeBuf[0].addr())
        if conn.isClient():
          data &= maskPayload(codeBuf)
        data &= codeBuf
      of Ping:
        data &= frameHeader.serialize(payload.pingBytes.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.pingBytes)
        data &= payload.pingBytes
      of Pong:
        data &= frameHeader.serialize(payload.pongBytes.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.pongBytes)
        data &= payload.pongBytes
      of Invalid:
        discard
      data
  )


proc serializeFragmentedStart*(conn: WebSocketConn, payload: WebSocketPayload): WebSocketPayloadBytes =
  WebSocketPayloadBytes(
    kind: payload.kind,
    data: block:
      var data: seq[byte]
      let frameHeader = WebSocketFrameHeader(
        fin: 0,
        opcode: payload.kind.toByte(),
        isMasked: if conn.isServer(): 0 else: 1,
        payloadLen: 0,
      )
      case payload.kind
      of Text:
        data &= frameHeader.serialize(payload.str.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.str)
        data &= payload.str.toOpenArrayByte(0, payload.str.high())
      of Binary:
        data &= frameHeader.serialize(payload.bytes.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.bytes)
        data &= payload.bytes
      else:
        discard
      data
  )


proc serializeFragmented*(conn: WebSocketConn, fin: bool, payload: WebSocketPayload): WebSocketPayloadBytes =
  WebSocketPayloadBytes(
    kind: payload.kind,
    data: block:
      var data: seq[byte]
      let frameHeader = WebSocketFrameHeader(
        fin: if fin: 1 else: 0,
        opcode: 0,
        isMasked: if conn.isServer(): 0 else: 1,
        payloadLen: 0,
      )
      case payload.kind
      of Text:
        data &= frameHeader.serialize(payload.str.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.str)
        data &= payload.str.toOpenArrayByte(0, payload.str.high())
      of Binary:
        data &= frameHeader.serialize(payload.bytes.len().uint64)
        if conn.isClient():
          data &= maskPayload(payload.bytes)
        data &= payload.bytes
      else:
        discard
      data
  )


proc send*(conn: WebSocketConn, payloadBytes: WebSocketPayloadBytes): Future[void] =
  ## Send data via tcp socket.
  ## Lifetime of `payloadBytes` must last until send completes.
  case payloadBytes.kind
  of Invalid:
    var fut = newFuture[void]("websocket.send")
    fut.complete()
    fut
  else:
    conn.socket.send(payloadBytes.data[0].addr(), payloadBytes.data.len())


proc close*(conn: WebSocketConn, code: uint16) {.async.} =
  ## Send the close frame and close the tcp socket.
  if not conn.isClosed():
    let payload = conn.serializeSingle(WebSocketPayload(kind: Close, code: code))
    await conn.send(payload)
    conn.deinit()
