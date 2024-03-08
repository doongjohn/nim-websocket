import std/asyncdispatch
import std/asynchttpserver
import ../src/websocket


proc webSocketLoop(conn: WebSocketConn) {.async.} =
  try:
    let payload1 = conn.payloadToBytes(WebSocketPayload(kind: Text, str: "1 message from server!"))
    let payload2 = conn.payloadToBytes(WebSocketPayload(kind: Text, str: "2 message from server!"))
    let payload3 = conn.payloadToBytes(WebSocketPayload(kind: Text, str: "3 message from server!"))
    let payload4 = conn.payloadToBytes(WebSocketPayload(kind: Text, str: "4 message from server!"))
    await all([
      conn.send(payload1),
      conn.send(payload2),
      conn.send(payload3),
      conn.send(payload4),
    ])

    while not conn.isClosed():
      let frameHeader = await conn.recvFrameHeader()

      if not conn.isValidMask(frameHeader):
        await conn.close(1002'u16)
        break

      conn.recvPayloadSingle(frameHeader):
        case payload.kind:
        of Text:
          echo "recv text: ", payload.str
        of Binary:
          echo "recv binary: ", payload.bytes
        of Close:
          echo "recv close: ", payload.code
          break
        of Ping:
          echo "recv ping: ", payload.pingBytes
          var pongPayload = conn.payloadToBytes(WebSocketPayload(kind: Pong, pongBytes: payload.pingBytes))
          await conn.send(pongPayload)
        of Pong:
          echo "recv pong: ", payload.pongBytes
        of Invalid:
          discard

      conn.recvPayloadFragmented(frameHeader):
        case payload.kind:
        of Text:
          if frameHeader.isFin():
            echo "recv text (fragmented last): ", payload.str
          else:
            echo "recv text (fragmented): ", payload.str
        of Binary:
          if frameHeader.isFin():
            echo "recv binary (fragmented last): ", payload.str
          else:
            echo "recv binary (fragmented): ", payload.str
        else:
          discard

  except WebSocketRecvError:
    echo "[error] socket recv failed"

  except CatchableError as err:
    echo "[error] exception: ", err.msg

  finally:
    conn.deinit()


proc acceptCallback(req: Request) {.async.} =
  if req.url.path == "/test":
    let conn = await webSocketAccept(req, "")
    if not conn.isNil():
      await conn.webSocketLoop()


proc main {.async.} =
  echo "websocket server start"
  var server = newAsyncHttpServer()
  server.listen(Port(8001), "localhost")
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(acceptCallback)


waitFor main()
