when defined(archivist_system_testing_options):
  import pkg/questionable
  import pkg/questionable/results
  import pkg/chronos
  import pkg/libp2p
  import ./manifest
  import ../node
  import ../units

  proc parseInstructions(instructionStr: string): seq[(string, string)] =
    var instructions = newSeq[(string, string)]()
    let tokens = instructionStr.split(";")
    for token in tokens:
      let tags = token.split("=")
      instructions.add((tags[0], tags[1]))
    return instructions

  proc getInstruction(instructions: seq[(string, string)], key: string): ?string = 
    for (k, v) in instructions:
      if key == k:
        return some(v)
    return none(string)

  proc loadManifest(node: ArchivistNodeRef, cidStr: string): Future[?!Manifest] {.async: (raises: [CancelledError]).} =
    without cid =? Cid.init(cidStr):
      return failure("invalid cidStr: " & cidStr)
    return await node.fetchManifest(cid)

  proc overrideDatasetSize(original: Manifest, instructions: seq[(string, string)]): NBytes =
    if size =? getInstruction(instructions, "datasetsize"):
      try:
        debugEcho "using new size: " & size
        return parseInt(size).NBytes
      except ValueError as exc:
        raiseAssert("SystemTesting: parseInt failed: " & exc.msg)
    debugEcho "using original size"
    return original.datasetSize

  proc tryCreateNewManifest(manifest: Manifest, datasetSize: NBytes): Manifest =
    let basicDatasetSize =
      if manifest.protected:
        manifest.originalDatasetSize
      else:
        datasetSize
    let basicTreeCid =
      if manifest.protected:
        manifest.originalTreeCid
      else:
        manifest.treeCid

    result = Manifest.new(
      treeCid = basicTreeCid,
      blockSize = manifest.blockSize,
      datasetSize = basicDatasetSize,
      version = manifest.version,
      hcodec = manifest.hcodec,
      codec = manifest.codec,
      protected = false,
      filename = manifest.filename,
      mimetype = manifest.mimetype,
    )

    if manifest.protected:
      result = Manifest.new(
        manifest = result,
        treeCid = manifest.treeCid,
        datasetSize = datasetSize,
        ecK = manifest.ecK,
        ecM = manifest.ecM,
        strategy = manifest.protectedStrategy
      )

      if manifest.verifiable:
        result = Manifest.new(
          manifest = result,
          verifyRoot = manifest.verifyRoot,
          slotRoots = manifest.slotRoots,
          cellSize = manifest.cellSize,
          strategy = manifest.verifiableStrategy
        ).get()

  proc createNewManifest(manifest: Manifest, datasetSize: NBytes): Manifest =
    try:
      return tryCreateNewManifest(manifest, datasetSize)
    except CatchableError as exc:
      raiseAssert("SystemTesting: failed to recreate manifest: " & exc.msg)

  proc modifyManifest*(node: ArchivistNodeRef, instructionStr: string): Future[string] {.async: (raises: [CancelledError]).} =
    let instructions = parseInstructions(instructionStr)
    if cidStr =? getInstruction(instructions, "cid"):
      without manifest =? (await loadManifest(node, cidStr)), err:
        raiseAssert("SystemTesting: failed to fetch manifest for cid: " & cidStr & " err: " & err.msg)

      let
        newDatasetSize = overrideDatasetSize(manifest, instructions)
        newManifest = createNewManifest(manifest, newDatasetSize)

      try:
        without manifestBlk =? (await node.storeManifest(newManifest)), err:
          raiseAssert("SystemTesting: failed to store modified manifest: " & err.msg)

        return $(manifestBlk.cid)
      except CatchableError as exc:
        raiseAssert("SystemTesting: failed to store modified manifest: " & exc.msg)
    raiseAssert("input cid missing")
