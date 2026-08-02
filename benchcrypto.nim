## Benchmark ChaChaPoly vs AES-GCM (NI + PCLMUL vs software) on x86_64
## Run on server1 (192.168.2.200) where AES-NI + PCLMULQDQ exist.

import std/monotimes, std/times, std/strutils

import bearssl/blockx
from stew/assign2 import assign
from stew/ptrops import baseAddr

import bearssl/abi/bearssl_aead
import bearssl/abi/bearssl_block
import bearssl/abi/bearssl_hash

const
  KeySize = 32
  NonceSize = 12
  TagSize = 16

type
  Key = array[KeySize, byte]
  Nonce = array[NonceSize, byte]
  Tag = array[TagSize, byte]

# ── ChaChaPoly (current Noise cipher) ──────────────────────────────

proc chachaCrypt(key: Key, nonce: Nonce, tag: var Tag,
                 data: var openArray[byte], aad: openArray[byte], encrypt: bool) =
  let ad = if aad.len > 0: unsafeAddr aad[0] else: nil
  poly1305CtmulRun(
    unsafeAddr key[0], unsafeAddr nonce[0], baseAddr(data),
    uint(data.len), ad, uint(aad.len), baseAddr(tag),
    cast[Chacha20Run](chacha20CtRun), if encrypt: 1.cint else: 0.cint
  )

# ── AES-GCM via AES-NI + PCLMULQDQ (hardware) ───────────────────────

var gcmCtxNi: GcmContext
var aesNiKeys: AesX86niCtrKeys

proc aesGcmNiInit(key: Key) =
  let ctrVt = aesX86niCtrGetVtable()
  if ctrVt == nil:
    echo "AES-NI: NOT available"
    return
  echo "AES-NI: available"
  aesX86niCtrInit(aesNiKeys, unsafeAddr key[0], uint(key.len))
  let gh = ghashPclmulGet()
  if gh == nil:
    echo "GHASH-PCLMUL: NOT available, using ctmul"
    gcmInit(gcmCtxNi, addr aesNiKeys.vtable, ghashCtmul)
  else:
    echo "GHASH-PCLMUL: available"
    gcmInit(gcmCtxNi, addr aesNiKeys.vtable, gh)

proc aesGcmNi(key: Key, nonce: Nonce, tag: var Tag,
              data: var openArray[byte], aad: openArray[byte], encrypt: bool) =
  gcmReset(gcmCtxNi, unsafeAddr nonce[0], uint(nonce.len))
  if aad.len > 0: gcmAadInject(gcmCtxNi, unsafeAddr aad[0], uint(aad.len))
  gcmFlip(gcmCtxNi)
  gcmRun(gcmCtxNi, if encrypt: 1.cint else: 0.cint, baseAddr(data), uint(data.len))
  gcmGetTag(gcmCtxNi, addr tag[0])

# ── AES-GCM via aes_big + ctmul (pure software) ─────────────────────

var gcmCtxCt: GcmContext
var aesCtKeys: AesBigCtrKeys

proc aesGcmCtInit(key: Key) =
  aesBigCtrInit(aesCtKeys, unsafeAddr key[0], uint(key.len))
  gcmInit(gcmCtxCt, addr aesCtKeys.vtable, ghashCtmul)

proc aesGcmCt(key: Key, nonce: Nonce, tag: var Tag,
              data: var openArray[byte], aad: openArray[byte], encrypt: bool) =
  gcmReset(gcmCtxCt, unsafeAddr nonce[0], uint(nonce.len))
  if aad.len > 0: gcmAadInject(gcmCtxCt, unsafeAddr aad[0], uint(aad.len))
  gcmFlip(gcmCtxCt)
  gcmRun(gcmCtxCt, if encrypt: 1.cint else: 0.cint, baseAddr(data), uint(data.len))
  gcmGetTag(gcmCtxCt, addr tag[0])

# ── Copy vs Move benchmark ──────────────────────────────────────────

proc benchCopy(data: var seq[byte]): seq[byte] =
  result = newSeq[byte](data.len)
  copyMem(addr result[0], addr data[0], data.len)

proc benchMove(data: var seq[byte]): seq[byte] =
  result = move(data)
  data = newSeq[byte](result.len)

# ── Harness ─────────────────────────────────────────────────────────

proc bench(name: string, procToRun: proc(), iters: int, size: int) =
  var totalNs: int64 = 0
  for i in 0 ..< min(iters div 10, 100): procToRun()
  for i in 0 ..< iters:
    let s = getMonoTime()
    procToRun()
    totalNs += (getMonoTime() - s).inNanoseconds
  let avgNs = totalNs div iters
  let mbps = float(size) / (float(avgNs) / 1e9) / 1e6
  echo name & ": " & $iters & "x" & $size & "B avg=" & $avgNs & "ns = " &
       mbps.formatFloat(ffDecimal, 1) & " MB/s"

proc benchCopyMove(name: string, procToRun: proc(data: var seq[byte]): seq[byte],
                   iters: int, size: int) =
  var d = newSeq[byte](size)
  for i in 0 ..< d.len: d[i] = byte(i and 0xFF)
  var totalNs: int64 = 0
  for i in 0 ..< iters:
    let s = getMonoTime()
    discard procToRun(d)
    totalNs += (getMonoTime() - s).inNanoseconds
  let avgNs = totalNs div iters
  let mbps = float(size) / (float(avgNs) / 1e9) / 1e6
  echo name & ": " & $iters & "x" & $size & "B avg=" & $avgNs & "ns = " &
       mbps.formatFloat(ffDecimal, 1) & " MB/s"

# ── Main ────────────────────────────────────────────────────────────

var key: Key
var nonce: Nonce
var tag: Tag
var aad: seq[byte] = newSeq[byte](32)
var data: seq[byte]

for i in 0 ..< key.len: key[i] = byte(i)
for i in 0 ..< nonce.len: nonce[i] = byte(i)
for i in 0 ..< aad.len: aad[i] = byte(i)

echo "=== Crypto: ChaChaPoly vs AES-GCM (NI+PCLMUL vs software) ==="
echo "Key=32B Nonce=12B Tag=16B AAD=32B"
echo ""

aesGcmNiInit(key)
aesGcmCtInit(key)

const ITERS = 500

for size in [4096, 16384, 65536, 262144, 1048576]:
  data = newSeq[byte](size)
  for i in 0 ..< data.len: data[i] = byte(i and 0xFF)

  bench("ChaChaPoly enc ", proc() = chachaCrypt(key, nonce, tag, data, aad, true),  ITERS, size)
  bench("ChaChaPoly dec ", proc() = chachaCrypt(key, nonce, tag, data, aad, false), ITERS, size)
  bench("AES-GCM-NI enc ", proc() = aesGcmNi(key, nonce, tag, data, aad, true),  ITERS, size)
  bench("AES-GCM-NI dec ", proc() = aesGcmNi(key, nonce, tag, data, aad, false), ITERS, size)
  bench("AES-GCM-CT enc ", proc() = aesGcmCt(key, nonce, tag, data, aad, true),  ITERS, size)
  bench("AES-GCM-CT dec ", proc() = aesGcmCt(key, nonce, tag, data, aad, false), ITERS, size)
  echo ""

echo "=== Copy vs Move (eqcopy: newSeq+copyMem vs sink/move) ==="
echo ""

for size in [65536, 262144, 1048576, 4194304, 16777216]:
  benchCopyMove("deep copy ", benchCopy, ITERS, size)
  benchCopyMove("sink/move ", benchMove, ITERS, size)
  echo ""