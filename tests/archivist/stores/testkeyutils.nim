## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/random
import std/sequtils
import pkg/chronos
import pkg/questionable/results
import pkg/libp2p
import pkg/archivist/blocktype as bt
import pkg/archivist/stores/repostore
import pkg/archivist/clock

import ../../asynctest
import ../helpers/mocktimer
import ../helpers/mockclock
import ../examples

import Archivist/Namespaces
import archivist/stores/keyutils

proc createManifestCid(): ?!Cid =
  let
    length = rand(4096)
    bytes = newSeqWith(length, rand(uint8))
    mcodec = Sha256HashCodec
    codec = ManifestCodec
    version = CIDv1

  let hash = ?MultiHash.digest($mcodec, bytes).mapFailure
  let cid = ?Cid.init(version, codec, hash).mapFailure
  return success cid

suite "KeyUtils":
  test "makePrefixKey should create block key":
    let length = 6
    let cid = Cid.example
    let expectedPrefix = ($cid)[^length ..^ 1]
    let expectedPostfix = $cid

    let key = !makePrefixKey(length, cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == ArchivistRepoNamespace
      namespaces[1].value == "blocks"
      namespaces[2].value == expectedPrefix
      namespaces[3].value == expectedPostfix

  test "makePrefixKey should create manifest key":
    let length = 6
    let cid = !createManifestCid().option
    let expectedPrefix = ($cid)[^length ..^ 1]
    let expectedPostfix = $cid

    let key = !makePrefixKey(length, cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 4
      namespaces[0].value == ArchivistRepoNamespace
      namespaces[1].value == "manifests"
      namespaces[2].value == expectedPrefix
      namespaces[3].value == expectedPostfix

  test "blockMetaKey should create block metadata key":
    let cid = Cid.example

    let key = !blockMetaKey(cid).option
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == ArchivistMetaNamespace
      namespaces[1].value == "blocks"
      namespaces[2].value == $cid

  test "blockMetaKeyQuery should create key for all block metadata entries":
    let key = !blockMetaKeyQuery().option
    let namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == ArchivistMetaNamespace
      namespaces[1].value == "blocks"
      namespaces[2].value == "*"

  test "treeNodeKey should create flat tree node key":
    let
      treeCid = Cid.example
      key = !treeNodeKey(treeCid, 42.Natural).option
      namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == ArchivistTreeNodeNamespace
      namespaces[1].value == $treeCid
      namespaces[2].value == "42"

  test "treeNodeQueryKey should create key for all tree nodes":
    let
      treeCid = Cid.example
      key = !treeNodeQueryKey(treeCid).option
      namespaces = key.namespaces

    check:
      namespaces.len == 3
      namespaces[0].value == ArchivistTreeNodeNamespace
      namespaces[1].value == $treeCid
      namespaces[2].value == "*"
