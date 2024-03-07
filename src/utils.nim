import std/endians
import std/asyncdispatch


proc fromBigEndian*[T: SomeInteger](inPtr: pointer): T =
  when system.cpuEndian == littleEndian:
    when T is uint16 | int16:
      swapEndian16(result.addr(), inPtr)
    elif T is uint32 | int32:
      swapEndian32(result.addr(), inPtr)
    elif T is uint64 | int64:
      swapEndian64(result.addr(), inPtr)
    else:
      {.error: "unsupported type".}
  else:
    when T is uint16 | int16:
      bigEndian16(result.addr(), inPtr)
    elif T is uint32 | int32:
      bigEndian32(result.addr(), inPtr)
    elif T is uint64 | int64:
      bigEndian64(result.addr(), inPtr)
    else:
      {.error: "unsupported type".}


proc toBigEndian*[T: SomeInteger](value: T, outPtr: pointer) =
  when system.cpuEndian == littleEndian:
    when T is uint16 | int16:
      swapEndian16(outPtr, value.addr())
    elif T is uint32 | int32:
      swapEndian32(outPtr, value.addr())
    elif T is uint64 | int64:
      swapEndian64(outPtr, value.addr())
    else:
      {.error: "unsupported type".}
  else:
    when T is uint16 | int16:
      bigEndian16(outPtr, value.addr())
    elif T is uint32 | int32:
      bigEndian32(outPtr, value.addr())
    elif T is uint64 | int64:
      bigEndian64(outPtr, value.addr())
    else:
      {.error: "unsupported type".}


proc stringFromBytes*(s: openArray[byte]): string =
  var str = newStringOfCap(s.len())
  str.setLen(s.len())
  copyMem(str[0].addr(), s[0].addr(), s.len())
  return str
