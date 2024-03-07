import std/bitops
import std/base64
import std/random
import std/asyncnet
import std/asyncdispatch
import std/asynchttpserver
import pkg/checksums/sha1
import utils


# TODO: max size of seq is `high(int)` but max size of websocket payload is `high(uint64)`
# TODO: send multiple times if payload is bigger than `high(int)`


type
  WebSocketRecvError* = object of IOError
  WebSocketSendError* = object of IOError


template newWebSocketRecvError*: untyped =
  newException(WebSocketRecvError, "recv failed")


template newWebSocketSendError*: untyped =
  newException(WebSocketSendError, "send failed")


type
  WebSocketPayloadType* = enum
    Text
    Binary
    Close
    Ping
    Pong
    Invalid

  WebSocketPayload* = object
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

  WebSocketFrameHeader* = object
    fin*: byte
    opcode*: byte
    isMasked*: byte
    payloadLen*: uint64

  WebSocketConn* = ref object
    socket*: AsyncSocket
    isServer: bool

    # recv data
    isRecvInitialFrame = true
    isRecvFragmented = false
    initialFrameOpcode: byte = 0
    payloadBuf: seq[byte] = @[]

    # send data
    isSendFragmented = false


proc payloadTypeToByte*(payloadType: WebSocketPayloadType): byte =
  case payloadType
  of Text: 0x1
  of Binary: 0x2
  of Close: 0x8
  of Ping: 0x9
  of Pong: 0xA
  else: 0x0


proc isFin*(frameHeader: WebSocketFrameHeader): bool =
  frameHeader.fin == 1


proc encode*(frameHeader: WebSocketFrameHeader, payloadLen: uint64): seq[byte] =
  result = @[0'u8, 0'u8]
  result[0] = result[0].setMasked(frameHeader.fin shl 7)
  result[0] = result[0].setMasked(frameHeader.opcode)
  result[1] = result[1].setMasked(frameHeader.isMasked shl 7)
  if payloadLen < 126:
    result[1] = result[1].setMasked(payloadLen.uint8)
  elif payloadLen <= uint16.high():
    result[1] = result[1].setMasked(126'u8)
    result &= [0'u8, 0'u8]
    payloadLen.uint16().toBigEndian(result[2].addr())
  else:
    result[1] = result[1].setMasked(127'u8)
    result &= [0'u8, 0'u8, 0'u8, 0'u8]
    payloadLen.toBigEndian(result[2].addr())


proc newWebSocketServer*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, isServer: true)


proc newWebSocketClient*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, isServer: false)


proc resetState*(self: WebSocketConn) =
  self.isRecvInitialFrame = true
  self.isRecvFragmented = false
  self.initialFrameOpcode = 0
  self.payloadBuf = @[]


proc deinit*(self: WebSocketConn) =
  ## Close connection without sending the close frame.
  self.resetState()
  self.socket.close()


proc close*(self: WebSocketConn, code: byte) =
  ## Close connection after sending the close frame.
  # TODO: send close frame
  self.deinit()


proc isClosed*(self: WebSocketConn): bool =
  self.socket.isClosed()


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

  const magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
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
  ## https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#decoding_payload_length
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
  ## https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data
  let maskingKey = rand(0'u32 .. uint32.high())
  copyMem(result[0].addr(), maskingKey.addr(), sizeof(maskingKey))
  for i in 0 ..< payload.len():
    payload[i] = payload[i] xor result[i mod 4]


proc maskPayload(payload: var string): array[4, byte] =
  ## https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data
  maskPayload(payload.toOpenArrayByte(0, payload.high()))


template unmaskPayload(maskingKey: array[4, byte], payload: var openArray[byte]) =
  ## https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#reading_and_unmasking_the_data
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
  conn.payloadBuf.setLen(payloadLen)

  if isMasked == 1:
    # recv masked payload
    let maskingKey = await conn.socket.recvMaskingKey()
    conn.socket.recvPayload(payloadLen, conn.payloadBuf)
    unmaskPayload(maskingKey, conn.payloadBuf)
  else:
    # recv unmasked payload
    conn.socket.recvPayload(payloadLen, conn.payloadBuf)

  # return payload
  if conn.isRecvFragmented:
    defer:
      if fin == 1:
        conn.resetState()
    case conn.initialFrameOpcode:
    of 0x1:
      return WebSocketPayload(kind: Text, str: stringFromBytes(conn.payloadBuf))
    of 0x2:
      return WebSocketPayload(kind: Binary, bytes: conn.payloadBuf)
    else:
      return WebSocketPayload(kind: Invalid)
  else:
    case opcode:
    of 0x1:
      return WebSocketPayload(kind: Text, str: stringFromBytes(conn.payloadBuf))
    of 0x2:
      return WebSocketPayload(kind: Binary, bytes: conn.payloadBuf)
    of 0x8:
      return WebSocketPayload(kind: Close, code: fromBigEndian[uint16](conn.payloadBuf[0].addr()))
    of 0x9:
      return WebSocketPayload(kind: Ping, pingBytes: conn.payloadBuf)
    of 0xA:
      return WebSocketPayload(kind: Pong, pongBytes: conn.payloadBuf)
    else:
      return WebSocketPayload(kind: Invalid)


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


proc send*(conn: WebSocketConn, payload: var WebSocketPayload): Future[void] =
  let frameHeader = WebSocketFrameHeader(
    fin: 1,
    opcode: payloadTypeToByte(payload.kind),
    isMasked: if conn.isServer: 0 else: 1,
    payloadLen: 0,
  )
  conn.isSendFragmented = false
  case payload.kind
  of Text:
    var buf = frameHeader.encode(payload.str.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.str)
    buf &= payload.str.toOpenArrayByte(0, payload.str.high())
    conn.socket.send(buf[0].addr(), buf.len())
  of Binary:
    var buf = frameHeader.encode(payload.bytes.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.bytes)
    buf &= payload.bytes
    conn.socket.send(buf[0].addr(), buf.len())
  of Close:
    var buf = frameHeader.encode(2'u64)
    var codeBuf = [0'u8, 0'u8]
    payload.code.toBigEndian(codeBuf[0].addr())
    if not conn.isServer:
      buf &= maskPayload(codeBuf)
    buf &= codeBuf
    conn.socket.send(buf[0].addr(), buf.len())
  of Ping:
    var buf = frameHeader.encode(payload.pingBytes.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.pingBytes)
    buf &= payload.pingBytes
    conn.socket.send(buf[0].addr(), buf.len())
  of Pong:
    var buf = frameHeader.encode(payload.pongBytes.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.pongBytes)
    buf &= payload.pongBytes
    conn.socket.send(buf[0].addr(), buf.len())
  of Invalid:
    var fut = newFuture[void]("websocket.send")
    fut.complete()
    fut


proc sendFragment*(conn: WebSocketConn, payload: var WebSocketPayload): Future[void] =
  let frameHeader = WebSocketFrameHeader(
    fin: 0,
    opcode:
      if not conn.isSendFragmented:
        payloadTypeToByte(payload.kind)
      else:
        0,
    isMasked: if conn.isServer: 0 else: 1,
    payloadLen: 0,
  )
  conn.isSendFragmented = true
  case payload.kind
  of Text:
    var buf = frameHeader.encode(payload.str.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.str)
    buf &= payload.str.toOpenArrayByte(0, payload.str.high())
    conn.socket.send(buf[0].addr(), buf.len())
  of Binary:
    var buf = frameHeader.encode(payload.bytes.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.bytes)
    buf &= payload.bytes
    conn.socket.send(buf[0].addr(), buf.len())
  else:
    var fut = newFuture[void]("websocket.sendFragment")
    fut.complete()
    fut


proc sendFragmentEnd*(conn: WebSocketConn, payload: var WebSocketPayload): Future[void] =
  let frameHeader = WebSocketFrameHeader(
    fin: 1,
    opcode: 0,
    isMasked: if conn.isServer: 0 else: 1,
    payloadLen: 0,
  )
  conn.isSendFragmented = false
  case payload.kind
  of Text:
    var buf = frameHeader.encode(payload.str.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.str)
    buf &= payload.str.toOpenArrayByte(0, payload.str.high())
    conn.socket.send(buf[0].addr(), buf.len())
  of Binary:
    var buf = frameHeader.encode(payload.bytes.len().uint64)
    if not conn.isServer:
      buf &= maskPayload(payload.bytes)
    buf &= payload.bytes
    conn.socket.send(buf[0].addr(), buf.len())
  else:
    var fut = newFuture[void]("websocket.sendFragmentEnd")
    fut.complete()
    fut
