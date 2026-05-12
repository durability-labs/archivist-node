import pkg/libp2p/stream/lpstream
import archivist/encryption/streams
import ../../asynctest
import ./examples

suite "stream encryption":
  test "encrypting stream can be created from a plaintext stream":
    let plaintext = LPStream.example
    check EncryptingStream.new(plaintext) != nil

  test "a new random key is created for each encrypting stream":
    let plaintext = LPStream.example
    let key1 = EncryptingStream.new(plaintext).key
    let key2 = EncryptingStream.new(plaintext).key
    check key1 != key2

  test "decrypting stream can be created from an encrypted stream and a key":
    let ciphertext = LPStream.example
    let key = EncryptionKey.example
    check DecryptingStream.new(ciphertext, key) != nil

  test "encrypted stream differs from plaintext":
    let plaintext = LPStream.example("hello")
    let encrypting = EncryptingStream.new(plaintext)
    var ciphertext = newString(5)
    await encrypting.readExactly(addr ciphertext[0], ciphertext.len)
    check ciphertext != "hello"

  test "encrypted stream can be decrypted":
    let plaintext = LPStream.example("hello\nworld\n")
    let encrypting = EncryptingStream.new(plaintext)
    let decrypting = DecryptingStream.new(encrypting, encrypting.key)
    check (await decrypting.readLine(sep = "\n")) == "hello"
    check (await decrypting.readLine(sep = "\n")) == "world"

  test "writing to an encrypting stream raises error":
    let plaintext = LPStream.example
    let encrypting = EncryptingStream.new(plaintext)
    expect LPStreamClosedError:
      await encrypting.write("hello")

  test "writing to a decrypting stream raises error":
    let ciphertext = LPStream.example
    let key = EncryptionKey.example
    let decrypting = DecryptingStream.new(ciphertext, key)
    expect LPStreamClosedError:
      await decrypting.write("hello")

  test "closing stream clears key from memory":
    let plaintext = LPStream.example
    let encrypting = EncryptingStream.new(plaintext)
    await encrypting.close()
    check encrypting.key == EncryptionKey.default
