# Archivist Codebase Guidelines for AI Agents

This document provides guidelines for AI agents working on the Archivist codebase.

## Code Style

### Formatting

- **Always run `nimble format`** before committing changes
- Uses [nph](https://github.com/arnetheduck/nph) for code formatting
- Format is enforced in CI

### Import Style

```nim
# External packages use pkg/ prefix
import pkg/chronos
import pkg/questionable
import pkg/questionable/results

# Local imports use relative paths
import ./types
import ../blockstore
import ../../errors
```

### Module Structure

```nim
## Copyright header (preserve existing)

{.push raises: [].}  # Module-level exception safety

import pkg/...
import ./...

logScope:
  topics = "archivist modulename"

# Types first, then procs
```

## Error Handling

**CRITICAL**: This is a complex P2P application with cryptographic proofs, distributed storage, and economic incentives (blockchain-based marketplace). Errors can lead to:
- Data loss or corruption
- Failed proof generation/verification
- Economic losses (slashed stakes, missed rewards)
- Network partitioning issues

**Never silently discard errors.** Every error must be either handled explicitly or propagated up the call stack.

### Prefer Result Types Over Exceptions

Use `?!T` (Result type from questionable/results) instead of raising exceptions:

```nim
# GOOD: Return Result type
proc doSomething(): Future[?!Value] {.async: (raises: [CancelledError]).} =
  if error:
    return failure(newException(SomeError, "message"))
  success(value)

# BAD: Raise exceptions
proc doSomething(): Future[Value] {.async.} =
  if error:
    raise newException(SomeError, "message")
  return value
```

### Exception Annotations

Always annotate async procs with explicit raises:

```nim
# GOOD: Explicit raises annotation
proc myProc(): Future[?!void] {.async: (raises: [CancelledError]).} =
  discard

# BAD: No raises annotation
proc myProc(): Future[?!void] {.async.} =
  discard
```

### Result Unwrapping Patterns

**Prefer `?` operator** for Result/Option unwrapping - it's concise and propagates errors automatically:

```nim
# BEST: ? operator (propagates error automatically)
proc doSomething(): Future[?!Value] {.async: (raises: [CancelledError]).} =
  let a = ?await getA()        # Returns failure if getA fails
  let b = ?await getB(a)       # Returns failure if getB fails
  success(combine(a, b))

# GOOD: without pattern (when you need custom error handling)
without value =? someResult, err:
  return failure(newException(CustomError, "context: " & err.msg))

# GOOD: without for Option (no error to capture)
without value =? someOption:
  return failure(newException(ValueError, "missing value"))

# ACCEPTABLE: =? with if (for branching, not error propagation)
if value =? someResult:
  # use value
```

### Error Propagation

**Prefer `?`** - it's the idiomatic way to propagate errors:

```nim
# BEST: ? operator
proc process(): Future[?!Result] {.async: (raises: [CancelledError]).} =
  let data = ?await fetchData()
  let parsed = ?parseData(data)
  let result = ?await saveResult(parsed)
  success(result)

# Use without only when you need to transform the error
without data =? await fetchData(), err:
  return failure(newException(ProcessError, "fetch failed: " & err.msg))
```

### Discarding Success Values (Not Errors)

When wrapping a function that returns `?!T` but you only need `?!void`, use `discard ?`:

```nim
# CORRECT: ? propagates error, discard only applies to success value
proc wrapper(): Future[?!void] {.async: (raises: [CancelledError]).} =
  discard ?await innerOp()  # Error propagated, only success value discarded

# WRONG: This silently ignores errors!
proc wrapper(): Future[?!void] {.async: (raises: [CancelledError]).} =
  discard await innerOp()  # Error lost! Never do this.
```

The `?` operator ensures the error is propagated. The `discard` only affects the unwrapped success value.

## Nim Idioms

### Prefer Functional Methods

Use `filter`, `filterIt`, `map`, `mapIt`, `foldl`, etc. over explicit for/while loops where possible:

```nim
# GOOD: Functional style - concise and consistent
let keys = cids.mapIt(makeBlockKey(it))
let nonEmpty = blocks.filterIt(not it.isEmpty)
let total = sizes.foldl(a + b, 0.NBytes)

# ACCEPTABLE: Loop when complex logic or early exit needed
var results: seq[Block]
for cid in cids:
  let blk = ?await getBlock(cid)
  if blk.isSpecial:
    break
  results.add(blk)

# AVOID: Loop when functional equivalent is cleaner
var keys: seq[Key]
for cid in cids:
  keys.add(makeBlockKey(cid))  # Use mapIt instead
```

### Be Judicious with Comments

Don't add comments for every change or obvious code. Comments should explain **why**, not **what**:

```nim
# GOOD: Explains non-obvious reasoning
# Metadata is source of truth - commit it last to ensure consistency
?await self.metaStore.put(records)

# BAD: States the obvious
# Increment the counter
counter.inc

# BAD: Documents breaking changes inline (use changelog instead)
# BREAKING: Removed expiry field
```

### Avoid Explicit `result`

Do not use the implicit `result` variable explicitly:

```nim
# GOOD: Return directly
proc getValue(): int =
  return 42

proc getValue(): int =
  42  # Last expression is returned

# BAD: Explicit result assignment
proc getValue(): int =
  result = 42
```

### Use `success()` and `failure()`

```nim
# For ?!void
return success()
return failure(err)

# For ?!T
return success(value)
return failure(newException(Error, "msg"))
```

### Constructor Pattern

Use `new` for **ref types** and `init` for **object types**:

```nim
# For ref types: use `new`
type MyRef* = ref object
  field*: int

func new*(T: type MyRef, param: int): MyRef =
  MyRef(field: param)

# For object types: use `init`
type MyObject* = object
  field*: int

func init*(T: type MyObject, param: int): MyObject =
  MyObject(field: param)

# Fallible construction (either type)
proc new*(T: type MyRef, param: int): ?!MyRef =
  if param < 0:
    return failure(newException(ValueError, "param must be >= 0"))
  success(MyRef(field: param))

proc init*(T: type MyObject, param: int): ?!MyObject =
  if param < 0:
    return failure(newException(ValueError, "param must be >= 0"))
  success(MyObject(field: param))
```

## Async Patterns

### Chronos Async

```nim
import pkg/chronos

proc myAsyncProc(): Future[?!Value] {.async: (raises: [CancelledError]).} =
  # CancelledError is the only exception that should propagate
  let result = await someOtherAsync()
  success(result)
```

### Cancellation Safety

Always consider cancellation in long-running operations:

```nim
proc longRunning(): Future[?!void] {.async: (raises: [CancelledError]).} =
  for item in items:
    await sleepAsync(1.seconds)  # Cancellation point
    # ... process item
```

## Testing

### Test Before Moving On (CRITICAL)

**Never move to the next feature until the current one compiles and all tests pass.**

1. **Compile first**: A failing compile means broken code. Fix it immediately.
2. **Test each functional unit**: Write tests as soon as a feature is complete.
3. **All tests must pass**: Do not proceed with new features while tests are failing.
4. **Fix issues immediately**: A failing test likely indicates a bug that will compound.

**Why this matters**: Broken code propagates. A small issue ignored now becomes a nightmare later. Each feature builds on the previous - if the foundation is broken, everything built on top will be broken too.

### Commit Each Work Unit (CRITICAL)

**Commit after completing each logical work unit before moving to the next.**

1. **Atomic commits**: Each commit should represent a complete, working unit of functionality
2. **Verify before commit**: Ensure tests pass and code compiles before committing
3. **Don't batch unrelated changes**: Keep commits focused on a single concern
4. **Commit message format**: Describe what was done and why (not just "update files")

**Workflow**:
```bash
# 1. Complete work unit
# 2. Verify it works
nim c -r tests/archivist/datasetmanager/testkeys.nim

# 3. Format code
nimble format

# 4. Commit with descriptive message
git add archivist/datasetmanager/keys.nim tests/archivist/datasetmanager/testkeys.nim
git commit -m "Add key builders for DatasetManager namespaces

- Implement key functions for /block, /meta/blocks, /meta/datasets paths
- Add slot and tree key builders
- Include comprehensive test coverage (19 tests)"
```

**Why this matters**: 
- Easier to review and understand changes
- Simpler to revert if something breaks
- Creates clear checkpoints in development
- Prevents loss of work if issues arise later

### Test Incrementally

**Focus on the unit you're working on.** Don't run the entire test suite every time - it's slow and makes it harder to isolate issues.

```bash
# Run specific test file for the module you're working on
nim c -r tests/testRepoStore.nim

# Run specific test suite
nim c -r tests/testDatasetManager.nim

# Run with a filter (if supported)
nim c -r tests/testRepoStore.nim -- "pattern"

# Only run full suite before committing or after major changes
nimble test
```

**Incremental testing workflow**:
1. Working on `stores/repostore/` → run `tests/archivist/stores/testrepostore.nim`
2. Working on `stores/cachestore.nim` → run `tests/archivist/stores/testcachestore.nim`
3. Working on `stores/maintenance.nim` → run `tests/archivist/stores/testmaintenance.nim`
4. Working on erasure coding → run `tests/archivist/testerasure.nim`
5. About to commit → run full `nimble test`

**Benefits**:
- Faster feedback loop
- Easier to isolate failures
- Less noise from unrelated tests
- More productive development

```bash
# Quick compile check (no full build)
nim c archivist/datasetmanager/types.nim

# Compile and run single test file
nim c -r tests/archivist/stores/testrepostore.nim

# Run the main node tests (includes most unit tests)
nim c -r tests/testNode.nim

# Full verification before commit
nimble build && nimble test && nimble format
```

**Test file locations**:
```
tests/
├── testNode.nim              # Main test runner (imports unit tests)
├── testContracts.nim         # Contract tests
├── testIntegration.nim       # Integration tests
└── archivist/
    ├── stores/
    │   ├── testrepostore.nim
    │   ├── testcachestore.nim
    │   └── testmaintenance.nim
    ├── merkletree/
    ├── slots/
    └── ...
```

### Test Structure

```nim
import pkg/asynctest
import pkg/questionable

suite "MyModule":
  test "should do something":
    let result = await myProc()
    check result.isOk
    check result.get == expectedValue
```

## Logging

Use chronicles with logScope:

```nim
import pkg/chronicles

logScope:
  topics = "archivist mymodule"

proc myProc() =
  trace "Starting operation", param = value
  debug "Debug info"
  info "Important info"
  warn "Warning message"
  error "Error occurred", err = msg
```

## Common Patterns in This Codebase

### BlockStore Pattern

```nim
method getBlock*(
    self: MyStore, cid: Cid
): Future[?!Block] {.base, async: (raises: [CancelledError]).} =
  without data =? await self.backend.get(key), err:
    if err of KeyNotFound:
      return failure(newException(BlockNotFoundError, err.msg))
    return failure(err)
  success(Block(cid: cid, data: data))
```

### Typed Datastore Modify Pattern

```nim
await self.metaDs.modifyGet(
  key,
  proc(maybeCurrent: ?MyType): Future[(?MyType, ResultType)] {.async.} =
    if current =? maybeCurrent:
      # Update existing
      (current.some, AlreadyExists)
    else:
      # Create new
      (MyType(field: value).some, Created)
)
```

## Things to Avoid

1. **Don't suppress type errors** with `{.cast(gcsafe).}` unless absolutely necessary
2. **Don't use `discard`** for important return values - handle errors explicitly
3. **Don't catch all exceptions** - be specific about what you handle
4. **Don't use global mutable state** - prefer passing dependencies explicitly
5. **Don't use `result =`** - return values directly
6. **Don't skip `raises` annotations** on async procs
7. **Don't move on with failing tests** - fix them first, broken code compounds
8. **Don't skip compilation checks** - if it doesn't compile, it's broken

## Serialization

### Protobuf for Persistence, JSON for REST API

**Use protobuf** for all persisted metadata - JSON is too slow.

```nim
# GOOD: Protobuf for storage
import pkg/libp2p/protobuf/minprotobuf

proc encode*(meta: MyMetadata): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, meta.field1.uint32)
  pb.write(2, meta.field2)
  pb.finish()
  pb.buffer

proc decode*(T: type MyMetadata, data: openArray[byte]): ?!T =
  var pb = initProtoBuffer(data)
  var field1: uint32
  if pb.getField(1, field1).isErr:
    return failure("Unable to decode field1")
  # ...
```

**JSON only for REST API responses** - not for storage.

See `archivist/manifest/coders.nim` for protobuf encoding patterns.

## Reference Files

Good examples of codebase patterns:
- `archivist/stores/repostore/operations.nim` - Result handling, async patterns
- `archivist/stores/blockstore.nim` - Interface definitions
- `archivist/blocktype.nim` - Type definitions with serialization
- `archivist/manifest/coders.nim` - Protobuf encoding/decoding patterns
