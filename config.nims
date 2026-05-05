--noNimblePath
include "vendor/nimble/paths.nims"
include "vendor/nimble/install.nims"

when defined(release):
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/release")
  )
else:
  switch(
    "nimcache", joinPath(currentSourcePath.parentDir, "nimcache/debug")
  )

# bypass Nim TLSF allocator to avoid cross-thread leaks
switch("define", "useMalloc")

when defined(release):
  switch("define", "danger")
  switch("opt", "speed")

  # Opt-in for local builds on toolchains known to support LTO.
  when defined(archivist_release_lto):
    switch("define", "lto")
    switch("define", "lto_incremental")
    switch("passC", "-flto")
    switch("passL", "-flto")
