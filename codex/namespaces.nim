## Copyright (c) 2025 Archivist authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

const
  # Namespaces
  ArchivistMetaNamespace* = "meta" # meta info stored here
  ArchivistRepoNamespace* = "repo" # repository namespace, blocks and manifests are subkeys
  ArchivistBlockTotalNamespace* = ArchivistMetaNamespace & "/total" # number of blocks in the repo
  ArchivistBlocksNamespace* = ArchivistRepoNamespace & "/blocks" # blocks namespace
  ArchivistManifestNamespace* = ArchivistRepoNamespace & "/manifests" # manifest namespace
  ArchivistBlocksTtlNamespace* = # Cid TTL
    ArchivistMetaNamespace & "/ttl"
  ArchivistBlockProofNamespace* = # Cid and Proof
    ArchivistMetaNamespace & "/proof"
  ArchivistDhtNamespace* = "dht" # Dht namespace
  ArchivistDhtProvidersNamespace* = # Dht providers namespace
    ArchivistDhtNamespace & "/providers"
  ArchivistQuotaNamespace* = ArchivistMetaNamespace & "/quota" # quota's namespace
