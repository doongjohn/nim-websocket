import std/bitops
import std/base64
import std/asyncnet
import std/asyncdispatch
import std/asynchttpserver
import pkg/checksums/sha1
import utils


# TODO
# 1. max size of seq is `high(int)` but max size of websocket payload is `high(uint64)`
# 2. implement send
# 3. implement client


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
    isInitialFrame = true
    isFragmented = false
    initialFrameOpcode: byte = 0
    payloadBuf: seq[byte] = @[]


proc isFin*(frameHeader: WebSocketFrameHeader): bool =
  frameHeader.fin == 1


proc newWebSocketServer*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, isServer: true)


proc newWebSocketClient*(socket: AsyncSocket): WebSocketConn =
  WebSocketConn(socket: socket, isServer: false)


proc resetState*(self: WebSocketConn) =
  self.isInitialFrame = true
  self.isFragmented = false
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


template decodePayload(maskingKey: array[4, byte], payload: var seq[byte]) =
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
  if not conn.isInitialFrame and fin == 1 and opcode != 0:
    conn.resetState()

  if conn.isInitialFrame:
    conn.isInitialFrame = false
    conn.initialFrameOpcode = opcode
    if fin == 0:
      conn.isFragmented = true

  # resize payload buffer
  conn.payloadBuf.setLen(payloadLen)

  if isMasked == 1:
    # recv masked payload
    let maskingKey = await conn.socket.recvMaskingKey()
    conn.socket.recvPayload(payloadLen, conn.payloadBuf)
    decodePayload(maskingKey, conn.payloadBuf)
  else:
    # recv unmasked payload
    conn.socket.recvPayload(payloadLen, conn.payloadBuf)

  # return payload
  if conn.isFragmented:
    defer:
      if fin == 1:
        conn.resetState()
    case conn.initialFrameOpcode:
    of 1:
      return WebSocketPayload(kind: Text, str: stringFromBytes(conn.payloadBuf))
    of 2:
      return WebSocketPayload(kind: Binary, bytes: conn.payloadBuf)
    else:
      return WebSocketPayload(kind: Invalid)
  else:
    case opcode:
    of 1:
      return WebSocketPayload(kind: Text, str: stringFromBytes(conn.payloadBuf))
    of 2:
      return WebSocketPayload(kind: Binary, bytes: conn.payloadBuf)
    of 8:
      return WebSocketPayload(kind: Close, code: fromBigEndian[uint16](conn.payloadBuf[0].addr()))
    of 9:
      return WebSocketPayload(kind: Ping, pingBytes: conn.payloadBuf)
    of 10:
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
