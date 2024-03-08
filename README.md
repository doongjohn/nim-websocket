# nim-websocket

Websocket server/client implementaion in Nim language.

## Features

- [x] Websocket server
- [x] Websocket client
- [x] Fragmentation
- [x] Ping/Pong frame

## Todo

- max size of seq is `high(int)` but max size of a websocket payload is `high(uint64)`
- send multiple times if payload is bigger than `high(int)`
- close frame message
