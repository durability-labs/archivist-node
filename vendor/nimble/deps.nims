import std/os
import std/strutils

type DepTaskError = object of CatchableError

proc raiseDepError(msg: string) {.noreturn.} =
  raise newException(DepTaskError, msg)

proc isWindowsReservedName(nameUpper: string): bool =
  ## Windows disallows these device names as path components, even with extensions.
  ## We conservatively reject them everywhere.
  let dot = nameUpper.find('.')
  let base = if dot >= 0: nameUpper[0 ..< dot] else: nameUpper
  if base in ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]:
    return true
  if base.len == 4 and base.startsWith("COM") and base[3] in {'1'..'9'}:
    return true
  if base.len == 4 and base.startsWith("LPT") and base[3] in {'1'..'9'}:
    return true
  false

proc isValidDepName(name: string): bool =
  ## Validates a directory-friendly dependency name.
  ##
  ## Rules:
  ## - non-empty
  ## - starts with alnum
  ## - contains only [A-Za-z0-9_.-]
  ## - rejects '.' and '..'
  if name.len == 0:
    return false
  if name == "." or name == "..":
    return false
  if not name[0].isAlphaNumeric:
    return false
  if name[^1] == '.':
    return false
  for ch in name:
    if ch.isAlphaNumeric or ch in {'_', '-', '.'}:
      continue
    return false
  if isWindowsReservedName(name.toUpperAscii()):
    return false
  true

proc sanitizeDepName*(name: string): string =
  ## Returns a sanitized dependency name or "" when invalid.
  let s = name.strip()
  if isValidDepName(s): s else: ""

proc isSafeShellArg(arg: string): bool =
  ## We run via `exec` which goes through a shell.
  ## Keep arguments simple to avoid quoting edge cases.
  if arg.len == 0:
    return false
  for ch in arg:
    if ch.isSpaceAscii:
      return false
    # NOTE: We avoid args that are commonly interpreted/expanded by shells.
    if ch in {'\"', '\'', '`', '$', '!', '%'}:
      return false
  true

proc deriveDepNameFromUrl*(url: string): string =
  var s = url.strip()
  if s.len == 0:
    return ""

  # Drop query/fragment to keep folder names stable.
  let q = s.find('?')
  if q >= 0:
    s = s[0 ..< q]
  let f = s.find('#')
  if f >= 0:
    s = s[0 ..< f]

  while s.endsWith('/'):
    s.setLen(s.len - 1)

  # Handle both https URLs and scp-like URLs (git@host:org/repo.git).
  let cut = max(s.rfind('/'), s.rfind(':'))
  var base = if cut >= 0: s[(cut + 1) .. ^1] else: s
  if base.endsWith(".git") and base.len > 4:
    base = base[0 .. ^5]

  result = sanitizeDepName(base)

proc shellJoin(args: openArray[string]): string =
  for i, a in args:
    if i > 0:
      result.add(' ')
    result.add(a.quoteShell)

proc execGit(args: openArray[string]) =
  if findExe("git").len == 0:
    raiseDepError("git not found in PATH")

  var parts: seq[string] = @["git"]
  for a in args:
    parts.add(a)
  try:
    exec(shellJoin(parts))
  except OSError as e:
    raiseDepError(e.msg)

proc gitGorgeEx(cwd: string, args: openArray[string]): tuple[output: string, exitCode: int] =
  if findExe("git").len == 0:
    raiseDepError("git not found in PATH")

  var parts: seq[string] = @["git"]
  for a in args:
    parts.add(a)
  let cmd = shellJoin(parts)

  withDir(cwd):
    let (output, exitCode) = gorgeEx(cmd)
    result = (output: output, exitCode: exitCode)

proc ensureGitRepo(rootDir: string) =
  if not (dirExists(rootDir / ".git") or fileExists(rootDir / ".git")):
    raiseDepError("Not a git repository (missing .git): " & rootDir)

proc addDep*(rootDir: string, url: string, nameOpt = "", rev = ""): string =
  if not dirExists(rootDir):
    raiseDepError("Invalid project directory: " & rootDir)
  ensureGitRepo(rootDir)

  if not isSafeShellArg(url):
    raiseDepError("Invalid git URL (whitespace/quotes not supported): " & url)
  if rev.len > 0 and not isSafeShellArg(rev):
    raiseDepError("Invalid git revision (whitespace/quotes not supported): " & rev)

  let vendorDir = rootDir / "vendor" / "nimble"
  if not dirExists(vendorDir):
    raiseDepError("Missing directory: " & vendorDir)

  let name =
    if nameOpt.len > 0:
      let sanitized = sanitizeDepName(nameOpt)
      if sanitized.len == 0:
        raiseDepError("Invalid dependency name: " & nameOpt & " (allowed: [A-Za-z0-9_.-], must start with alnum)")
      sanitized
    else:
      let derived = deriveDepNameFromUrl(url)
      if derived.len == 0:
        raiseDepError("Could not derive dependency name from URL; pass an explicit [name]")
      derived

  let dest = vendorDir / name
  if dirExists(dest) or fileExists(dest):
    raiseDepError("Destination already exists: " & dest)

  # Use forward slashes for git args to avoid Windows quoting edge cases.
  let destGit = "vendor/nimble/" & name

  withDir(rootDir):
    # `vendor/nimble/*` may be gitignored; use -f to allow adding submodules.
    execGit(["submodule", "add", "-f", "--", url, destGit])

  if rev.len > 0:
    withDir(dest):
      execGit(["checkout", rev])

  withDir(dest):
    execGit(["submodule", "update", "--init", "--recursive"])

  result = name

proc isGitSubmoduleDeclared(rootDir: string, pathGit: string): bool =
  let gm = rootDir / ".gitmodules"
  if not fileExists(gm):
    return false
  try:
    return readFile(gm).contains("path = " & pathGit)
  except OSError:
    return false

proc isPorcelainV1StatusLine(line: string): bool =
  ## `git status --porcelain=v1` emits lines like:
  ##   XY <path>
  ##   ?? <path>
  if line.len < 3:
    return false
  if line[0] == '?' and line[1] == '?' and line[2] == ' ':
    return true
  if line[2] != ' ':
    return false
  const valid = {' ', 'M', 'A', 'D', 'R', 'C', 'U', 'T'}
  (line[0] in valid) and (line[1] in valid)

proc removeDep*(rootDir: string, nameOpt: string, force = false, prune = false) =
  if not dirExists(rootDir):
    raiseDepError("Invalid project directory: " & rootDir)
  ensureGitRepo(rootDir)

  let name = sanitizeDepName(nameOpt)
  if name.len == 0:
    raiseDepError("Invalid dependency name: " & nameOpt & " (allowed: [A-Za-z0-9_.-], must start with alnum)")

  let pathGit = "vendor/nimble/" & name
  if not isGitSubmoduleDeclared(rootDir, pathGit):
    raiseDepError("Dependency not found in .gitmodules: " & pathGit)

  let pathFs = rootDir / "vendor" / "nimble" / name

  if not force:
    var modifiedReason = ""

    # Detect submodule revision drift from superproject's POV.
    let (subOut, subCode) = gitGorgeEx(rootDir, ["submodule", "status", "--", pathGit])
    if subCode == 0 and subOut.len > 0:
      let prefix = subOut[0]
      if prefix in {'+', 'U'}:
        modifiedReason = "submodule is not at recorded revision"

    # Detect local uncommitted changes inside the submodule.
    if modifiedReason.len == 0 and dirExists(pathFs) and (dirExists(pathFs / ".git") or fileExists(pathFs / ".git")):
      let (stOut, stCode) = gitGorgeEx(pathFs, ["status", "--porcelain=v1"])
      if stCode != 0:
        modifiedReason = "unable to determine submodule status"
      else:
        let stClean = stOut.strip()
        if stClean.len > 0:
          var porcelainLines: seq[string] = @[]
          var unexpectedLines: seq[string] = @[]
          for line in stClean.splitLines():
            if line.len == 0:
              continue
            # In NimScript, some execution environments may emit bookkeeping
            # lines that are not part of `git status` porcelain output.
            if line.startsWith("[NimScript]"):
              continue
            if isPorcelainV1StatusLine(line):
              porcelainLines.add(line)
            else:
              unexpectedLines.add(line)

          if porcelainLines.len > 0:
            modifiedReason = "submodule has local changes\n" & porcelainLines.join("\n")
          elif unexpectedLines.len > 0:
            modifiedReason = "unable to determine submodule status\n" & unexpectedLines.join("\n")

    if modifiedReason.len > 0:
      raiseDepError("Refusing to remove " & name & ": " & modifiedReason & " (use --force to override)")

  withDir(rootDir):
    execGit(["submodule", "deinit", "-f", "--", pathGit])
    execGit(["rm", "-f", "--", pathGit])

  if prune:
    let modulesDir = rootDir / ".git" / "modules" / "vendor" / "nimble" / name
    if dirExists(modulesDir):
      try:
        rmDir(modulesDir)
      except OSError as e:
        raiseDepError("Failed to prune " & modulesDir & ": " & e.msg)

proc hasHelpFlag(args: seq[string]): bool =
  for a in args:
    if a == "--help" or a == "-h":
      return true
  false

proc printAddDepUsage() =
  echo "Usage: nimble addDep <git-url> [name] [rev]"

proc printRemoveDepUsage() =
  echo "Usage: nimble removeDep <name> [--force] [--prune]"

proc nimbleTaskArgs(): seq[string] =
  ## Extracts args that come after the task/action name.
  ##
  ## Nimble executes `.nimble` files through `nim e`, passing compiler flags,
  ## the generated script file, the project file, an out file, the action name
  ## and finally the task arguments.
  ##
  ## We mirror Nimble's own internal parsing so task arg handling is stable.
  var scriptFile = ""
  var projectFile = ""
  var outFile = ""
  var actionName = ""
  for i in 2 .. paramCount():
    let p = paramStr(i)
    if actionName.len == 0:
      if p.len == 0:
        continue
      # Skip compiler flags before we reach the action name.
      if p[0] == '-':
        continue
      if scriptFile.len == 0:
        scriptFile = p
      elif projectFile.len == 0:
        projectFile = p
      elif outFile.len == 0:
        outFile = p
      else:
        actionName = p.normalize
    else:
      result.add(p)

proc addDepTask*(rootDir: string) =
  let args = nimbleTaskArgs()
  if args.len == 0 or hasHelpFlag(args):
    printAddDepUsage()
    return

  try:
    if args.len > 3:
      raiseDepError("Too many arguments")
    if args[0].len > 0 and args[0][0] == '-':
      raiseDepError("Unknown option: " & args[0])

    let url = args[0]
    let nameOpt = if args.len >= 2: args[1] else: ""
    let rev = if args.len >= 3: args[2] else: ""

    let name = addDep(rootDir=rootDir, url=url, nameOpt=nameOpt, rev=rev)
    echo "Added dependency: vendor/nimble/" & name
  except CatchableError as e:
    echo "Error: " & e.msg
    printAddDepUsage()

proc removeDepTask*(rootDir: string) =
  let rawArgs = nimbleTaskArgs()
  if rawArgs.len == 0 or hasHelpFlag(rawArgs):
    printRemoveDepUsage()
    return

  var force = false
  var prune = false
  var pos: seq[string] = @[]
  var stopOpts = false

  for a in rawArgs:
    if not stopOpts and a == "--":
      stopOpts = true
      continue
    if not stopOpts and a == "--force":
      force = true
      continue
    if not stopOpts and a == "--prune":
      prune = true
      continue
    if not stopOpts and (a == "--help" or a == "-h"):
      printRemoveDepUsage()
      return
    if not stopOpts and a.len > 0 and a[0] == '-':
      echo "Error: Unknown option: " & a
      printRemoveDepUsage()
      return
    pos.add(a)

  if pos.len != 1:
    printRemoveDepUsage()
    return

  let nameOpt = pos[0]

  try:
    removeDep(rootDir=rootDir, nameOpt=nameOpt, force=force, prune=prune)
    echo "Removed dependency: vendor/nimble/" & sanitizeDepName(nameOpt)
  except CatchableError as e:
    echo "Error: " & e.msg
    printRemoveDepUsage()
