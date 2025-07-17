import ./merkletree/merkletree
import ./merkletree/archivist
import ./merkletree/poseidon2

export archivist, poseidon2, merkletree

type
  SomeMerkleTree* = ByteTree | ArchivistTree | Poseidon2Tree
  SomeMerkleProof* = ByteProof | ArchivistProof | Poseidon2Proof
  SomeMerkleHash* = ByteHash | Poseidon2Hash
