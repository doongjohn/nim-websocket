import std/asyncdispatch
import std/asynchttpserver
import websocket


proc webSocketLoop(conn: WebSocketConn) {.async.} =
  try:
    while not conn.isClosed():
      let frameHeader = await conn.recvFrameHeader()

      conn.recvPayloadSingle(frameHeader):
        case payload.kind:
        of Text:
          echo "recv text: ", payload.str
        of Binary:
          echo "recv binary: ", payload.bytes
        of Close:
          echo "recv close: ", payload.code
          break
        else:
          discard

      conn.recvPayloadFragmented(frameHeader):
        case payload.kind:
        of Text:
          if frameHeader.fin == 1:
            echo "recv text (fragmented last): ", payload.str
          else:
            echo "recv text (fragmented): ", payload.str
        of Binary:
          if frameHeader.fin == 1:
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
  var server = newAsyncHttpServer()
  server.listen(Port(8001), "localhost")
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(acceptCallback)


waitFor main()
