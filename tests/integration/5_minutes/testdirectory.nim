import std/json
import std/strutils
import pkg/asynctest/chronos/unittest2
import pkg/questionable
import pkg/stew/byteutils
import ../../testbed

suite "Directory Manifests":
  var testbed: Testbed
  var node1, node2: Node

  setup:
    testbed = await Testbed.start()
    node1 = await testbed.node.start()
    node2 = await testbed.node.start()

  teardown:
    await testbed.stop()

  test "can create directory from uploaded files":
    # Upload files with paths
    let file1 = await testbed.dataset.data("file 1 content").filename("photos/img1.jpg").upload(node1)
    let file2 = await testbed.dataset.data("file 2 content").filename("photos/img2.jpg").upload(node1)
    let file3 = await testbed.dataset.data("readme content").filename("docs/readme.md").upload(node1)

    # Create directory
    let dirResponse = await testbed.api(node1).createDirectory(
      "MyAlbum",
      @[!file1.cid, !file2.cid, !file3.cid]
    )

    check dirResponse{"cid"}.getStr().len > 0
    check dirResponse{"fileCount"}.getInt() == 3
    check dirResponse{"protected"}.getBool() == false

  test "can browse directory listing":
    # Upload files
    let file1 = await testbed.dataset.data("content 1").filename("a.txt").upload(node1)
    let file2 = await testbed.dataset.data("content 2").filename("b.txt").upload(node1)

    # Create directory
    let dirResponse = await testbed.api(node1).createDirectory(
      "TestDir",
      @[!file1.cid, !file2.cid]
    )
    let dirCid = dirResponse{"cid"}.getStr()

    # Browse directory
    let listing = await testbed.api(node1).getDirectoryListing(dirCid)

    check listing{"name"}.getStr() == "TestDir"
    check listing{"fileCount"}.getInt() == 2
    check listing{"entries"}{"a.txt"}.getStr() == !file1.cid
    check listing{"entries"}{"b.txt"}.getStr() == !file2.cid

  test "directory preserves upload order":
    # Upload files in specific order
    let file1 = await testbed.dataset.data("z content").filename("z_last.txt").upload(node1)
    let file2 = await testbed.dataset.data("a content").filename("a_first.txt").upload(node1)
    let file3 = await testbed.dataset.data("m content").filename("m_middle.txt").upload(node1)

    # Create directory with specific order
    let dirResponse = await testbed.api(node1).createDirectory(
      "OrderedDir",
      @[!file1.cid, !file2.cid, !file3.cid]
    )
    let dirCid = dirResponse{"cid"}.getStr()

    # Browse directory and verify order
    let listing = await testbed.api(node1).getDirectoryListing(dirCid)
    let entries = listing{"entries"}

    var keys: seq[string]
    for key in entries.keys:
      keys.add(key)

    check keys[0] == "z_last.txt"
    check keys[1] == "a_first.txt"
    check keys[2] == "m_middle.txt"

  test "can access individual files from directory":
    # Upload file with path
    let fileData = "individual file content"
    let file1 = await testbed.dataset.data(fileData).filename("folder/file.txt").upload(node1)

    # Create directory
    discard await testbed.api(node1).createDirectory("TestDir", @[!file1.cid])

    # Access individual file directly by CID
    let download = await testbed.api(node1).download(!file1.cid, network = false)
    check string.fromBytes(download) == fileData

  test "file without path uses CID as filename":
    # Upload file without filename header
    let headers = @{"Content-Disposition": "attachment"}
    let file1 = await testbed.dataset.data("no path content").upload(node1, headers = headers)

    # Create directory
    let dirResponse = await testbed.api(node1).createDirectory("NoPathDir", @[!file1.cid])
    let dirCid = dirResponse{"cid"}.getStr()

    # Browse directory - file should use CID as path
    let listing = await testbed.api(node1).getDirectoryListing(dirCid)
    let entries = listing{"entries"}

    # The key should be the CID string
    check entries{!file1.cid}.getStr() == !file1.cid

  test "directory rejects duplicate paths":
    # Upload two files with same path
    let file1 = await testbed.dataset.data("content 1").filename("same.txt").upload(node1)
    let file2 = await testbed.dataset.data("content 2").filename("same.txt").upload(node1)

    # Try to create directory - should fail due to duplicate paths
    try:
      discard await testbed.api(node1).createDirectory("DupDir", @[!file1.cid, !file2.cid])
      fail()
    except HttpError as error:
      check "500" in error.msg or "Duplicate" in error.msg

  test "directory rejects invalid CIDs":
    try:
      discard await testbed.api(node1).createDirectory("BadDir", @["not-a-valid-cid"])
      fail()
    except HttpError as error:
      check "400" in error.msg

  test "directory rejects empty entries":
    try:
      discard await testbed.api(node1).createDirectory("EmptyDir", @[])
      fail()
    except HttpError as error:
      check "400" in error.msg

  test "directory with nested paths":
    # Upload files with deep nested paths
    let file1 = await testbed.dataset.data("deep content").filename("a/b/c/d/file.txt").upload(node1)

    let dirResponse = await testbed.api(node1).createDirectory("DeepDir", @[!file1.cid])
    let dirCid = dirResponse{"cid"}.getStr()

    let listing = await testbed.api(node1).getDirectoryListing(dirCid)
    check listing{"entries"}{"a/b/c/d/file.txt"}.getStr() == !file1.cid

  test "single file directory":
    let file1 = await testbed.dataset.data("single file").filename("only.txt").upload(node1)

    let dirResponse = await testbed.api(node1).createDirectory("SingleDir", @[!file1.cid])

    check dirResponse{"fileCount"}.getInt() == 1
