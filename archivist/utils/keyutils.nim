## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push:
  {.upraises: [].}

import pkg/questionable/results
import pkg/libp2p/crypto/crypto

import ./fileutils
import ../errors
import ../logutils
import ../rng

export crypto

type
  ArchivistKeyError = object of ArchivistError
  ArchivistKeyUnsafeError = object of ArchivistKeyError

proc setupKey*(path: string): ?!PrivateKey =
  if not path.fileAccessible({AccessFlags.Find}):
    info "Creating a private key and saving it"
    let
      res = ?PrivateKey.random(Rng.instance()[]).mapFailure(ArchivistKeyError)
      bytes = ?res.getBytes().mapFailure(ArchivistKeyError)

    ?path.secureWriteFile(bytes).mapFailure(ArchivistKeyError)
    return PrivateKey.init(bytes).mapFailure(ArchivistKeyError)

  info "Found a network private key"
  if not ?checkSecureFile(path).mapFailure(ArchivistKeyError):
    warn "The network private key file is not safe, aborting"
    return failure newException(
      ArchivistKeyUnsafeError, "The network private key file is not safe"
    )

  let kb = ?path.readAllBytes().mapFailure(ArchivistKeyError)
  return PrivateKey.init(kb).mapFailure(ArchivistKeyError)
