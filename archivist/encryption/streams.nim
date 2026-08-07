import pkg/chronos
import pkg/libp2p/stream/lpstream
import pkg/nimcrypto/rijndael
import pkg/nimcrypto/bcmode
import pkg/nimcrypto/utils
import ../rng

{.push raises: [].}

## Encrypting and decrypting streams for dataset upload and download.
## Uses AES-128 CTR encryption with random keys and an IV that is 0.
##
## For each dataset a unique random key is generated. A combination of CID and
## key allows a person to download and decrypt the dataset. We chose 128 bits of
## security because that allows for smaller keys. AES-128 is considered strong
## enough for post-quantum security.
## We use a constant IV of 0, to avoid having to add the IV to the CID/key
## combination. This is safe, because we never reuse a key to encrypt more than
## one dataset.
## CTR block cipher mode is used, because it allows for random access and
## parallel decryption to be implemented later. Malleability of the ciphertext
## is not a problem here, because we already authenticate the contents of the
## dataset using the SHA hash from the CID.
##
## references:
##   - Block cipher mode CTR
##     https://en.wikipedia.org/wiki/Block_cipher_mode_of_operation#Counter_(CTR)
##   - Quantum Computers Are Not a Threat to 128-bit Symmetric Keys
##     https://words.filippo.io/128-bits/
##   - Constant IV when keys are not reused
##     https://crypto.stackexchange.com/a/1570

type
  EncryptingStream* = ref object of AesStream
  DecryptingStream* = ref object of AesStream
  EncryptionKey* = AesKey
  AesKey = array[aes128.sizeKey, byte]
  AesStream = ref object of LPStream
    key: AesKey
    context: CTR[aes128]
    source: LPStream

const ZeroIV = array[aes128.sizeBlock, byte].default

proc new*(
    _: type EncryptingStream, plaintext: LPStream, rng = Rng.instance
): EncryptingStream =
  const name = "EncryptingStream"
  let stream = EncryptingStream(source: plaintext, objName: name)
  initStream(stream)
  rng[].generate(stream.key)
  stream.context.init(stream.key, ZeroIV)
  stream

proc new*(
    _: type DecryptingStream, ciphertext: LPStream, key: EncryptionKey
): DecryptingStream =
  const name = "DecryptingStream"
  let stream = DecryptingStream(key: key, source: ciphertext, objName: name)
  initStream(stream)
  stream.context.init(stream.key, ZeroIV)
  stream

func key*(stream: EncryptingStream): AesKey =
  stream.key

method atEof(stream: AesStream): bool =
  stream.source.atEof()

method readOnce(
    stream: AesStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  let length = await stream.source.readOnce(pbytes, nbytes)
  let inout = cast[ptr byte](pbytes)
  # AES CTR encryption and decryption are the same operation
  stream.context.encrypt(inout, inout, length.uint)
  length

method write(
    stream: AesStream, _: seq[byte]
) {.async: (raises: [CancelledError, LPStreamError]).} =
  raise newLPStreamClosedError()

method closeImpl(stream: AesStream) {.async: (raises: []).} =
  await stream.source.closeImpl()
  stream.context.clear()
  burnMem(stream.key)
  await procCall LPStream(stream).closeImpl()
