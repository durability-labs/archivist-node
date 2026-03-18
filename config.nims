--noNimblePath
include "vendor/nimble/paths.nims"

when defined(release):
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/release/$projectName")
  )
else:
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/debug/$projectName")
  )

# bypass Nim TLSF allocator to avoid cross-thread free accumulation
switch("define", "useMalloc")

when defined(release):
  switch("define", "danger")
  # enable LTO
  switch("define", "lto")
  switch("define", "lto_incremental")
  switch("passC", "-flto")
  switch("passl", "-flto")
