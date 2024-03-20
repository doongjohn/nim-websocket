# Package

version       = "0.1.0"
author        = "doongjohn"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.1.1"
requires "checksums"


task build_example, "build example server and client":
  echo "building server"
  exec "nim c --hints:off -o:build/server.exe example/server.nim"

  echo "building client"
  exec "nim c --hints:off -o:build/client.exe example/client.nim"
