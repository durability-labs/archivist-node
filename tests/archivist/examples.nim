import std/random
import std/sequtils
import pkg/libp2p
import pkg/ethers
import pkg/archivist/conf
import pkg/archivist/rng
import pkg/archivist/stores
import pkg/archivist/blocktype as bt
import pkg/archivist/marketplace/sales
import pkg/archivist/merkletree
import pkg/archivist/manifest
import ../examples

export examples

proc example*(_: type EthAddress): EthAddress =
  Wallet.createRandom().address

proc example*(_: type bt.Block, size: int = 4096): bt.Block =
  let length = rand(size)
  let bytes = newSeqWith(length, rand(uint8))
  bt.Block.new(bytes).tryGet()

proc example*(_: type PeerId): PeerId =
  let key = libp2p.PrivateKey.random(rng.Rng.instance[]).get
  PeerId.init(key.getPublicKey().get).get

proc example*(_: type BlockExcPeerCtx): BlockExcPeerCtx =
  BlockExcPeerCtx.new(PeerId.example)

proc example*(_: type Cid): Cid =
  bt.Block.example.cid

proc example*(_: type Manifest): Manifest =
  Manifest.new(
    treeCid = Cid.example,
    blockSize = 256.NBytes,
    datasetSize = 4096.NBytes,
    filename = "example.txt".some,
    mimetype = "text/plain".some,
  )

proc example*(_: type MultiHash, mcodec = Sha256HashCodec): MultiHash =
  let bytes = newSeqWith(256, rand(uint8))
  MultiHash.digest($mcodec, bytes).tryGet()

proc example*(_: type MerkleProof): MerkleProof =
  MerkleProof.init(3, @[MultiHash.example]).tryget()

proc example*(_: type Poseidon2Proof): Poseidon2Proof =
  var example = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]()
  example.index = 123
  example.path = @[1, 2, 3, 4].mapIt(it.toF)
  example
