import std/strformat
import std/asyncdispatch
import std/asynchttpserver
import ../src/websocket


proc webSocketLoop(conn: WebSocketConn) {.async.} =
  try:
    while not conn.isClosed():
      let frameHeader = await conn.recvFrameHeader()

      if not conn.isValidMask(frameHeader):
        await conn.close(1002'u16)
        break

      conn.recvPayloadSingle(frameHeader):
        case payload.kind:
        of Text:
          echo "recv text: ", payload.str
          let textPayload = conn.payloadToBytes(WebSocketPayload(
            kind: Text,
            str: "client text recv success: {payload.str}".fmt(),
          ))
          await conn.send(textPayload)
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


proc main {.async.} =
  echo "websocket client start"
  let conn = await webSocketConnect("ws://localhost:8001/test", "")
  if not conn.isNil():
    await conn.webSocketLoop()


waitFor main()
