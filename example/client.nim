import std/strformat
import std/asyncdispatch
import std/asynchttpserver
import ../src/websocket


proc webSocketLoop(conn: WebSocketConn) {.async.} =
  try:
    while not conn.isClosed():
      let frameHeader = await conn.recvFrameHeader()
      if not conn.isMaskValid(frameHeader):
        await conn.close(1002)
        break

      conn.recvPayloadSingle(frameHeader):
        case payload.kind:
        of Text:
          echo "recv text: ", payload.str
          await conn.send(WebSocketPayload(
            kind: Text,
            str: "client text recv success: {payload.str}".fmt(),
          ))
        of Binary:
          echo "recv binary: ", payload.bytes
        of Close:
          echo "recv close: ", payload.code
          break
        of Ping:
          echo "recv ping: ", payload.pingBytes
          await conn.send(WebSocketPayload(kind: Pong, pongBytes: payload.pingBytes))
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
            echo "recv binary (fragmented last): ", payload.bytes
          else:
            echo "recv binary (fragmented): ", payload.bytes
        else:
          discard

  except WebSocketRecvError:
    echo "[error] socket recv failed"

  except CatchableError as err:
    echo "[error] exception: ", err.msg

  finally:
    conn.deinit()


proc main {.async.} =
  echo "websocket client start"

  const url = "ws://localhost:8001/test"
  var conn = await webSocketConnect(url, "")
  while conn.isNil():
    await sleepAsync(1000)
    echo "connecting..."
    conn = await webSocketConnect(url, "")

  await conn.webSocketLoop()


waitFor main()
