## Memory allocation helpers for FFI
##
## This file provides memory allocation utilities for the library's FFI layer.
## These helpers are designed for thread-safe shared memory allocation.

{.pragma: exported, exportc, cdecl, raises: [].}

################################################################################
### SharedSeq type for thread-safe sequences

type SharedSeq*[T] = tuple[data: ptr UncheckedArray[T], len: int]

################################################################################
### String allocation helpers (shared memory for thread safety)

proc alloc*(str: cstring): cstring =
  if str.isNil:
    var ret = cast[cstring](allocShared(1))
    ret[0] = '\0'
    return ret

  let ret = cast[cstring](allocShared(len(str) + 1))
  copyMem(ret, str, len(str) + 1)
  return ret

proc alloc*(str: string): cstring =
  if str.len == 0:
    var ret = cast[cstring](allocShared(1))
    ret[0] = '\0'
    return ret

  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

proc allocCString*(s: string): cstring =
  return alloc(s)

proc deallocCString*(s: cstring) =
  if not s.isNil:
    deallocShared(s)

################################################################################
### Buffer allocation helpers

proc allocBuffer*(size: csize_t): pointer =
  if size == 0:
    return nil
  result = allocShared0(size)

proc deallocBuffer*(p: pointer) =
  ## Free a buffer allocated by allocBuffer.
  if not p.isNil:
    deallocShared(p)

################################################################################
### SharedSeq helpers

proc allocSharedSeq*[T](s: seq[T]): SharedSeq[T] =
  let data = allocShared(sizeof(T) * s.len)
  if s.len != 0:
    copyMem(data, unsafeAddr s[0], sizeof(T) * s.len)
  return (cast[ptr UncheckedArray[T]](data), s.len)

proc deallocSharedSeq*[T](s: var SharedSeq[T]) =
  ## Free a SharedSeq.
  deallocShared(s.data)
  s.len = 0

proc toSeq*[T](s: SharedSeq[T]): seq[T] =
  var ret = newSeq[T]()
  for i in 0 ..< s.len:
    ret.add(s.data[i])
  return ret

################################################################################
### Safe string copy

proc copyToBuffer*(dest: pointer, src: string, maxSize: csize_t): csize_t =
  if dest.isNil or maxSize == 0:
    return 0
  let copyLen = min(src.len, maxSize.int)
  copyMem(dest, unsafeAddr src[0], copyLen)
  return copyLen.csize_t

################################################################################
### Shared object allocation

proc createShared*[T](): ptr T =
  result = cast[ptr T](allocShared0(sizeof(T)))

proc createShared*[T](val: T): ptr T =
  result = cast[ptr T](allocShared0(sizeof(T)))
  result[] = val

proc destroyShared*[T](p: ptr T) =
  if not p.isNil:
    deallocShared(p)
