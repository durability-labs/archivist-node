import std/os
import std/tempfiles

import pkg/questionable/results

import pkg/chronos
import pkg/kvstore
import pkg/kvstore/fsds
import pkg/taskpools

import pkg/archivist/stores
import pkg/archivist/stores/repostore/types

import ../../../asynctest
import ../../helpers

import ./overlays/helpers

proc testStartup*(
    name: string,
    repoDsProvider: KVStoreProvider,
    metaDsProvider: KVStoreProvider,
    before: Before = nil,
    after: After = nil,
) =
  suite name:
    var
      repoDs: KVStore
      metaDs: KVStore

    setup:
      if not isNil(before):
        await before()
      repoDs = repoDsProvider()
      metaDs = metaDsProvider()

    teardown:
      (await repoDs.close()).tryGet
      (await metaDs.close()).tryGet
      if not isNil(after):
        await after()

    test "Should set started flag once started":
      let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
      await repo.start()
      check repo.started

    test "Should set started flag to false once stopped":
      let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
      await repo.start()
      await repo.stop()
      check not repo.started

    test "Should allow start to be called multiple times":
      let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
      await repo.start()
      await repo.start()
      check repo.started

    test "Should allow stop to be called multiple times":
      let repo = RepoStore.new(repoDs, metaDs, quotaMaxBytes = 200'nb)
      await repo.stop()
      await repo.stop()
      check not repo.started

proc runFsSqliteTests() =
  let repoDir = createTempDir("archivist-", "-repostore")

  testStartup(
    "RepoStore startup FS+SQLite backend",
    repoDsProvider = proc(): KVStore =
      if not dirExists(repoDir):
        createDir(repoDir)
      let tp = Taskpool.new()
      FSKVStore.new(repoDir, tp, depth = 5).tryGet(),
    metaDsProvider = proc(): KVStore =
      let tp = Taskpool.new()
      SQLiteKVStore.new(SqliteMemory, tp).tryGet(),
    after = proc(): Future[void] {.async.} =
      os.removeDir(repoDir),
  )

runFsSqliteTests()
