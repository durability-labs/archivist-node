## Copyright (c) 2025 Archivist Authors
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## Partially taken from nim beacon chain

{.push raises: [].}

import std/strutils
import pkg/stew/io2

import ../logutils

export io2
export logutils

const
  MaxPathDepth* = 20
    ## Maximum allowed nesting depth for virtual paths (e.g., a/b/c/d/...)
  MaxPathLength* = 4096
    ## Maximum allowed path length in bytes

proc isValidVirtualPath*(path: string): bool =
  ## Validates a virtual path for use in directory manifests.
  ## 
  ## Validation rules:
  ## - No null bytes (injection prevention)
  ## - No ".." segments (directory traversal)
  ## - No leading "/" (path must be relative)
  ## - No backslash characters (prevent Windows path injection)
  ## - Path length must not exceed MaxPathLength
  ## - Path depth must not exceed MaxPathDepth levels
  ## 
  ## Empty paths are valid (used for root-level files that will use CID as name).
  ##
  ## Examples:
  ##   isValidVirtualPath("file.txt") == true
  ##   isValidVirtualPath("photos/2024/img.jpg") == true
  ##   isValidVirtualPath("../etc/passwd") == false
  ##   isValidVirtualPath("/absolute/path") == false
  ##   isValidVirtualPath("path\\with\\backslash") == false

  # Empty path is valid - file goes in root directory using CID as name
  if path.len == 0:
    return true

  # Check path length
  if path.len > MaxPathLength:
    return false

  # No null bytes
  if '\0' in path:
    return false

  # No backslash characters
  if '\\' in path:
    return false

  # No leading slash (path must be relative)
  if path.startsWith("/"):
    return false

  # No trailing slash
  if path.endsWith("/"):
    return false

  # Check for ".." segments and count depth
  let segments = path.split('/')
  var depth = 0
  for segment in segments:
    # No empty segments (would mean consecutive slashes like "a//b")
    if segment.len == 0:
      return false

    # No ".." segments (directory traversal)
    if segment == "..":
      return false

    # Count non-"." segments for depth
    if segment != ".":
      inc depth

  # Check depth limit
  if depth > MaxPathDepth:
    return false

  return true

when defined(windows):
  import stew/windows/acl

proc secureCreatePath*(path: string): IoResult[void] =
  when defined(windows):
    let sres = createFoldersUserOnlySecurityDescriptor()
    if sres.isErr():
      error "Could not allocate security descriptor",
        path = path, errorMsg = ioErrorMsg(sres.error), errorCode = $sres.error
      err(sres.error)
    else:
      var sd = sres.get()
      createPath(path, 0o700, secDescriptor = sd.getDescriptor())
  else:
    createPath(path, 0o700)

proc secureWriteFile*[T: byte | char](
    path: string, data: openArray[T]
): IoResult[void] =
  when defined(windows):
    let sres = createFilesUserOnlySecurityDescriptor()
    if sres.isErr():
      error "Could not allocate security descriptor",
        path = path, errorMsg = ioErrorMsg(sres.error), errorCode = $sres.error
      err(sres.error)
    else:
      var sd = sres.get()
      writeFile(path, data, 0o600, secDescriptor = sd.getDescriptor())
  else:
    writeFile(path, data, 0o600)

proc checkSecureFile*(path: string): IoResult[bool] =
  when defined(windows):
    checkCurrentUserOnlyACL(path)
  else:
    ok (?getPermissionsSet(path) == {UserRead, UserWrite})

proc checkAndCreateDataDir*(dataDir: string): bool =
  when defined(posix):
    let requiredPerms = 0o700
    if isDir(dataDir):
      let currPermsRes = getPermissions(dataDir)
      if currPermsRes.isErr():
        fatal "Could not check data directory permissions",
          data_dir = dataDir,
          errorCode = $currPermsRes.error,
          errorMsg = ioErrorMsg(currPermsRes.error)
        return false
      else:
        let currPerms = currPermsRes.get()
        if currPerms != requiredPerms:
          warn "Data directory has insecure permissions. Correcting them.",
            data_dir = dataDir,
            current_permissions = currPerms.toOct(4),
            required_permissions = requiredPerms.toOct(4)
          let newPermsRes = setPermissions(dataDir, requiredPerms)
          if newPermsRes.isErr():
            fatal "Could not set data directory permissions",
              data_dir = dataDir,
              errorCode = $newPermsRes.error,
              errorMsg = ioErrorMsg(newPermsRes.error),
              old_permissions = currPerms.toOct(4),
              new_permissions = requiredPerms.toOct(4)
            return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data directory",
          data_dir = dataDir, errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  elif defined(windows):
    let amask = {AccessFlags.Read, AccessFlags.Write, AccessFlags.Execute}
    if fileAccessible(dataDir, amask):
      let cres = checkCurrentUserOnlyACL(dataDir)
      if cres.isErr():
        fatal "Could not check data folder's ACL",
          data_dir = dataDir, errorCode = $cres.error, errorMsg = ioErrorMsg(cres.error)
        return false
      else:
        if cres.get() == false:
          warn "Data folder has insecure ACL. Correcting it.", data_dir = dataDir
          let newPermsRes = setCurrentUserOnlyAccess(dataDir)
          if newPermsRes.isErr():
            fatal "Could not set data directory ACL",
              data_dir = dataDir,
              errorCode = $newPermsRes.error,
              errorMsg = ioErrorMsg(newPermsRes.error)
            return false
    else:
      let res = secureCreatePath(dataDir)
      if res.isErr():
        fatal "Could not create data folder",
          data_dir = dataDir, errorMsg = ioErrorMsg(res.error), errorCode = $res.error
        return false
  else:
    fatal "Unsupported operation system"
    return false

  return true
