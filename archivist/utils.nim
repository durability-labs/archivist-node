## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

{.push raises: [].}

import std/parseutils
import std/options

import pkg/chronos
import pkg/stew/bitseqs

import ./utils/asyncheapqueue
import ./utils/fileutils
import ./utils/asynciter
import ./utils/safeasynciter
import ./utils/asyncbarrier
import ./utils/futures

export
  asyncheapqueue, fileutils, asynciter, safeasynciter, chronos, bitseqs, asyncbarrier

when defined(posix):
  import os, posix

type Bytes = seq[byte]

func combineSafe*(tgt: var BitSeq, src: BitSeq) =
  ## OR-combine two BitSeqs that may have different lengths.
  ##

  if Bytes(src).len == 0:
    return

  if Bytes(tgt).len == 0:
    tgt = BitSeq.init(src.len)
    for i in 0 ..< src.len:
      if src[i]:
        tgt.setBit(i)
    return

  if tgt.len == src.len:
    tgt.combine(src)
    return

  let minLen = min(tgt.len, src.len)

  # OR the overlapping portion
  for i in 0 ..< minLen:
    if src[i]:
      tgt.setBit(i)

  # Extend tgt with src's extra bits
  for i in minLen ..< src.len:
    tgt.add(src[i])

func divUp*[T: SomeInteger](a, b: T): T =
  ## Division with result rounded up (rather than truncated as in 'div')
  assert(b != T(0))
  if a == T(0):
    T(0)
  else:
    ((a - T(1)) div b) + T(1)

func roundUp*[T](a, b: T): T =
  ## Round up 'a' to the next value divisible by 'b'
  divUp(a, b) * b

iterator batches*[T](values: openArray[T], batchSize: Positive): seq[T] =
  var offset = 0
  while offset < values.len:
    let batchEnd = min(offset + batchSize, values.len)
    yield @values[offset ..< batchEnd]
    offset = batchEnd

proc orElse*[A](a, b: Option[A]): Option[A] =
  if (a.isSome()): a else: b

when not declared(parseDuration): # Odd code formatting to minimize diff v. mainLine
  const Whitespace = {' ', '\t', '\v', '\r', '\l', '\f'}

  func toLowerAscii(c: char): char =
    if c in {'A' .. 'Z'}:
      char(uint8(c) xor 0b0010_0000'u8)
    else:
      c

  func parseDuration*(s: string, size: var Duration): int =
    ## Parse a size qualified by simple time into `Duration`.
    ##
    runnableExamples:
      var res: Duration # caller must still know if 'b' refers to bytes|bits
      doAssert parseDuration("10H", res) == 3
      doAssert res == initDuration(hours = 10)
      doAssert parseDuration("64m", res) == 6
      doAssert res == initDuration(minutes = 64)
      doAssert parseDuration("7m/block", res) == 2 # '/' stops parse
      doAssert res == initDuration(minutes = 7) # 1 shl 30, forced binary metric
      doAssert parseDuration("3d", res) == 2 # '/' stops parse
      doAssert res == initDuration(days = 3) # 1 shl 30, forced binary metric

    const prefix = "s" & "mhdw" # byte|bit & lowCase metric-ish prefixes
    const timeScale = [1.0, 60.0, 3600.0, 86_400.0, 604_800.0]

    var number: float
    var scale = 1.0
    result = parseFloat(s, number)
    if number < 0: # While parseFloat accepts negatives ..
      result = 0 #.. we do not since sizes cannot be < 0
    else:
      let start = result # Save spot to maybe unwind white to EOS
      while result < s.len and s[result] in Whitespace:
        inc result
      if result < s.len: # Illegal starting char => unity
        if (let si = prefix.find(s[result].toLowerAscii); si >= 0):
          inc result # Now parse the scale
          scale = timeScale[si]
      else: # Unwind result advancement when there..
        result = start #..is no unit to the end of `s`.
      var sizeF = number * scale + 0.5 # Saturate to int64.high when too big
      size = seconds(int(sizeF))

# Block all/most signals in the current thread, so we don't interfere with regular signal
# handling elsewhere.
proc ignoreSignalsInThread*() =
  when defined(posix):
    var signalMask, oldSignalMask: Sigset

    # sigprocmask() doesn't work on macOS, for multithreaded programs
    if sigfillset(signalMask) != 0:
      echo osErrorMsg(osLastError())
      quit(QuitFailure)
    when defined(boehmgc):
      # Turns out Boehm GC needs some signals to deal with threads:
      # https://www.hboehm.info/gc/debugging.html
      const
        SIGPWR = 30
        SIGXCPU = 24
        SIGSEGV = 11
        SIGBUS = 7
      if sigdelset(signalMask, SIGPWR) != 0 or sigdelset(signalMask, SIGXCPU) != 0 or
          sigdelset(signalMask, SIGSEGV) != 0 or sigdelset(signalMask, SIGBUS) != 0:
        echo osErrorMsg(osLastError())
        quit(QuitFailure)
    if pthread_sigmask(SIG_BLOCK, signalMask, oldSignalMask) != 0:
      echo osErrorMsg(osLastError())
      quit(QuitFailure)
