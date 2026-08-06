## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [].}

import ../errors

type MerkleTreeIndexError* = object of ArchivistError

func divUp2(x: int): int {.inline.} =
  (x + 1) div 2

func validateLeaves(nleaves: int): ?!void =
  if nleaves <= 0:
    return failure(newException(MerkleTreeIndexError, "nleaves must be greater than 0"))

  success()

func layerWidth*(nleaves, level: int): ?!int =
  ## Return the number of nodes in a logical layer.
  ##
  ## A single leaf still has a bottom layer and a compressed root layer.
  ?validateLeaves(nleaves)
  if level < 0:
    return failure(
      newException(MerkleTreeIndexError, "level must be greater than or equal to 0")
    )

  var
    width = nleaves
    currentLevel = 0

  if level == currentLevel:
    return success(width)

  while true:
    width = divUp2(width)
    currentLevel.inc
    if level == currentLevel:
      return success(width)
    if width == 1:
      break

  return failure(newException(MerkleTreeIndexError, "level is out of bounds"))

func levels*(nleaves: int): ?!int =
  ## Return total layer count, including the leaf layer and root layer.
  ?validateLeaves(nleaves)

  var
    width = nleaves
    count = 1

  while true:
    width = divUp2(width)
    count.inc
    if width == 1:
      break

  success(count)

func levelOffset*(nleaves, level: int): ?!int =
  ## Return the flat-array offset for a layer.
  let totalLevels = ?levels(nleaves)
  if level < 0 or level >= totalLevels:
    return failure(newException(MerkleTreeIndexError, "level is out of bounds"))

  var offset = 0
  for i in 0 ..< level:
    offset += ?layerWidth(nleaves, i)

  success(offset)

func flatIndex*(nleaves, level, index: int): ?!int =
  ## Return the flat-array index for a node at a layer/index pair.
  if index < 0:
    return failure(
      newException(MerkleTreeIndexError, "index must be greater than or equal to 0")
    )

  let width = ?layerWidth(nleaves, level)
  if index >= width:
    return failure(newException(MerkleTreeIndexError, "index is out of bounds"))

  success((?levelOffset(nleaves, level)) + index)

func totalNodes*(nleaves: int): ?!int =
  ## Return the total number of nodes in the flattened tree.
  let totalLevels = ?levels(nleaves)

  var total = 0
  for level in 0 ..< totalLevels:
    total += ?layerWidth(nleaves, level)

  success(total)
