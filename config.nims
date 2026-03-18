--noNimblePath
include "vendor/nimble/paths.nims"
include "vendor/nimble/install.nims"

when defined(release):
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/release/$projectName")
  )
else:
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/debug/$projectName")
  )

# bypass Nim TLSF allocator to avoid cross-thread leaks
switch("define", "useMalloc")

when defined(release):
  switch("define", "danger")
  # enable LTO
  switch("define", "lto")
  switch("define", "lto_incremental")
  switch("passC", "-flto")
  switch("passl", "-flto")
  # CPU-specific optimizations (use native arch)
  switch("passC", "-march=native")
  switch("passl", "-march=native")
  # Optimize for speed over size
  switch("opt", "speed")
  switch("passC", "-O3")
