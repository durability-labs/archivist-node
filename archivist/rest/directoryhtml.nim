## Copyright (c) 2025 Archivist Authors
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# HTML template for directory listing with Archivist branding

{.push raises: [].}

import std/strutils
import std/strformat
import std/options

import pkg/libp2p/cid

import ../manifest/directory
import ../units

const ArchivistLogoSvg* = """<svg version="1.0" xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 400 400" preserveAspectRatio="xMidYMid meet">
<g transform="translate(0,400) scale(0.1,-0.1)" fill="#00ff41" stroke="none">
<path d="M1750 3254 c-135 -79 -371 -217 -525 -305 -154 -89 -310 -180 -348 -201 l-67 -40 2 -691 3 -690 280 -165 c154 -90 294 -172 310 -182 55 -31 499 -292 548 -321 26 -16 49 -29 52 -29 2 0 60 33 127 73 68 41 245 145 393 232 149 87 359 210 467 274 l197 116 1 665 c0 366 3 675 6 687 7 25 25 12 -246 170 -91 52 -277 161 -415 241 -393 228 -538 312 -539 311 -1 0 -111 -66 -246 -145z m308 -306 c22 -40 113 -215 202 -388 89 -173 197 -380 240 -460 146 -274 300 -579 300 -594 0 -29 -17 -24 -106 28 -484 288 -687 406 -698 406 -7 0 -187 -102 -400 -226 -213 -124 -391 -223 -394 -219 -6 6 64 150 151 310 23 44 83 157 131 250 49 94 123 235 166 315 42 80 112 213 155 295 43 83 90 173 105 200 15 28 39 74 54 103 14 28 33 52 40 52 8 0 32 -33 54 -72z"/>
<g transform="translate(1988,2200) scale(0.75) translate(-1988,-2200)">
<path d="M1890 2712 c-62 -119 -168 -320 -235 -447 -67 -126 -153 -288 -190 -360 -38 -71 -88 -166 -112 -209 -24 -43 -42 -80 -40 -82 1 -2 79 42 172 98 395 234 485 287 503 292 13 5 118 -53 353 -195 184 -110 340 -205 347 -211 6 -6 12 -7 12 -4 0 7 -86 171 -120 231 -10 17 -57 107 -105 200 -49 94 -114 217 -144 275 -31 58 -114 220 -185 360 -71 140 -132 258 -135 262 -4 5 -58 -90 -121 -210z"/>
</g>
</g>
</svg>"""

const DirectoryListingCss* = """
:root {
  --bg-primary: #0d1117;
  --bg-secondary: #161b22;
  --bg-tertiary: #21262d;
  --text-primary: #c9d1d9;
  --text-secondary: #8b949e;
  --accent: #00ff41;
  --accent-dim: #00cc33;
  --link: #58a6ff;
  --link-hover: #79c0ff;
  --border: #30363d;
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
  background-color: var(--bg-primary);
  color: var(--text-primary);
  line-height: 1.5;
  min-height: 100vh;
}

.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 0 16px;
}

header {
  background-color: var(--bg-secondary);
  border-bottom: 1px solid var(--border);
  padding: 16px 0;
  position: sticky;
  top: 0;
  z-index: 100;
}

.header-content {
  display: flex;
  align-items: center;
  gap: 16px;
}

.logo {
  display: flex;
  align-items: center;
  gap: 8px;
  text-decoration: none;
  color: var(--accent);
  font-weight: 600;
  font-size: 18px;
}

.logo svg {
  flex-shrink: 0;
}

.breadcrumb {
  display: flex;
  align-items: center;
  gap: 4px;
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 14px;
  color: var(--text-secondary);
  flex-wrap: wrap;
}

.breadcrumb a {
  color: var(--link);
  text-decoration: none;
}

.breadcrumb a:hover {
  text-decoration: underline;
}

.breadcrumb .separator {
  color: var(--text-secondary);
}

main {
  padding: 24px 0;
}

.dir-info {
  background-color: var(--bg-secondary);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 16px;
  margin-bottom: 16px;
}

.dir-info h1 {
  font-size: 20px;
  font-weight: 600;
  margin-bottom: 8px;
  display: flex;
  align-items: center;
  gap: 8px;
}

.dir-meta {
  font-size: 13px;
  color: var(--text-secondary);
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
}

.dir-meta .cid {
  word-break: break-all;
}

.dir-meta a {
  color: var(--link);
  text-decoration: none;
}

.dir-meta a:hover {
  text-decoration: underline;
}

.file-list {
  background-color: var(--bg-secondary);
  border: 1px solid var(--border);
  border-radius: 6px;
  overflow: hidden;
}

.file-list-header {
  display: grid;
  grid-template-columns: 1fr 200px 100px;
  gap: 16px;
  padding: 12px 16px;
  background-color: var(--bg-tertiary);
  border-bottom: 1px solid var(--border);
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.file-row {
  display: grid;
  grid-template-columns: 1fr 200px 100px;
  gap: 16px;
  padding: 10px 16px;
  border-bottom: 1px solid var(--border);
  font-size: 14px;
  transition: background-color 0.1s;
}

.file-row:last-child {
  border-bottom: none;
}

.file-row:hover {
  background-color: var(--bg-tertiary);
}

.file-name {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}

.file-name a {
  color: var(--link);
  text-decoration: none;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.file-name a:hover {
  text-decoration: underline;
}

.file-icon {
  flex-shrink: 0;
  font-size: 16px;
}

.file-cid {
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 12px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.file-cid a {
  color: var(--text-secondary);
  text-decoration: none;
}

.file-cid a:hover {
  color: var(--link);
}

.file-size {
  text-align: right;
  color: var(--text-secondary);
  font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  font-size: 13px;
}

.parent-link {
  color: var(--text-secondary) !important;
}

.empty-dir {
  padding: 48px 16px;
  text-align: center;
  color: var(--text-secondary);
}

footer {
  padding: 24px 0;
  text-align: center;
  color: var(--text-secondary);
  font-size: 12px;
  border-top: 1px solid var(--border);
  margin-top: 48px;
}

footer a {
  color: var(--accent);
  text-decoration: none;
}

footer a:hover {
  text-decoration: underline;
}

@media (max-width: 768px) {
  .file-list-header,
  .file-row {
    grid-template-columns: 1fr 80px;
  }

  .file-cid {
    display: none;
  }

  .header-content {
    flex-direction: column;
    align-items: flex-start;
  }
}
"""

proc formatSize*(bytes: NBytes): string =
  ## Format bytes into human-readable size
  let b = bytes.int64
  if b < 1024:
    return $b & " B"
  elif b < 1024 * 1024:
    return fmt"{b.float / 1024.0:.1f} KB"
  elif b < 1024 * 1024 * 1024:
    return fmt"{b.float / (1024.0 * 1024.0):.1f} MB"
  else:
    return fmt"{b.float / (1024.0 * 1024.0 * 1024.0):.2f} GB"

proc getFileIcon*(entry: DirectoryEntry): string =
  ## Get appropriate icon for file type
  if entry.isDirectory:
    return "&#128193;" # folder icon

  if entry.mimetype.len == 0:
    return "&#128196;" # generic file icon

  let mime = entry.mimetype

  if mime.startsWith("image/"):
    return "&#128247;" # camera/image icon
  elif mime.startsWith("video/"):
    return "&#127909;" # video icon
  elif mime.startsWith("audio/"):
    return "&#127925;" # music icon
  elif mime.startsWith("text/"):
    return "&#128221;" # text icon
  elif mime == "application/pdf":
    return "&#128213;" # book icon
  elif mime == "application/zip" or mime == "application/x-tar" or
       mime == "application/gzip" or mime == "application/x-7z-compressed":
    return "&#128230;" # archive icon
  elif mime == "application/json" or mime == "application/xml":
    return "&#128196;" # code/file icon
  else:
    return "&#128196;" # generic file icon

proc escapeHtml*(s: string): string =
  ## Escape HTML special characters
  result = s
  result = result.replace("&", "&amp;")
  result = result.replace("<", "&lt;")
  result = result.replace(">", "&gt;")
  result = result.replace("\"", "&quot;")
  result = result.replace("'", "&#39;")

proc truncateCid*(cidStr: string, maxLen: int = 16): string =
  ## Truncate CID for display
  if cidStr.len <= maxLen:
    return cidStr
  let halfLen = (maxLen - 3) div 2
  return cidStr[0 ..< halfLen] & "..." & cidStr[^halfLen .. ^1]

proc generateDirectoryHtml*(
    directory: DirectoryManifest,
    dirCid: Cid,
    basePath: string = "",
    parentCid: Option[Cid] = none(Cid),
): string =
  ## Generate HTML page for directory listing
  ##
  ## basePath: the path within the directory (e.g., "/subdir/nested")
  ## parentCid: CID of parent directory for ".." link

  let
    cidStr = $dirCid
    dirName = if directory.name.len > 0: directory.name else: cidStr[0 ..< 12] & "..."
    escapedDirName = escapeHtml(dirName)
    pathParts = if basePath.len > 0: basePath.strip(chars = {'/'}).split('/') else: @[]

  var html = fmt"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Index of {escapedDirName} - Archivist</title>
  <style>
{DirectoryListingCss}
  </style>
</head>
<body>
  <header>
    <div class="container">
      <div class="header-content">
        <a href="/" class="logo">
          {ArchivistLogoSvg}
          <span>Archivist</span>
        </a>
        <nav class="breadcrumb">
          <a href="/api/archivist/v1/data/{cidStr}">{truncateCid(cidStr, 12)}</a>
"""

  # Add breadcrumb for nested paths
  var currentPath = ""
  for i, part in pathParts:
    currentPath &= "/" & part
    html &= fmt"""          <span class="separator">/</span>
          <a href="/api/archivist/v1/data/{cidStr}{currentPath}">{escapeHtml(part)}</a>
"""

  html &= fmt"""        </nav>
      </div>
    </div>
  </header>

  <main>
    <div class="container">
      <div class="dir-info">
        <h1>&#128193; Index of {escapedDirName}</h1>
        <div class="dir-meta">
          <span class="cid">CID: <a href="/api/archivist/v1/data/{cidStr}">{cidStr}</a></span>
          &nbsp;&bull;&nbsp;
          <span>{directory.entries.len} items</span>
          &nbsp;&bull;&nbsp;
          <span>{formatSize(directory.totalSize)}</span>
        </div>
      </div>

      <div class="file-list">
        <div class="file-list-header">
          <span>Name</span>
          <span>CID</span>
          <span style="text-align: right">Size</span>
        </div>
"""

  # Add parent directory link if we have a parent
  if parentCid.isSome:
    let parentCidStr = $parentCid.unsafeGet()
    html &= fmt"""        <div class="file-row">
          <div class="file-name">
            <span class="file-icon">&#128193;</span>
            <a href="/api/archivist/v1/data/{parentCidStr}" class="parent-link">..</a>
          </div>
          <div class="file-cid">
            <a href="/api/archivist/v1/data/{parentCidStr}">{truncateCid(parentCidStr)}</a>
          </div>
          <div class="file-size">-</div>
        </div>
"""
  elif basePath.len > 0:
    # Parent is same directory, just go up one path level
    let parentPath = if pathParts.len > 1:
        "/" & pathParts[0 ..< ^1].join("/")
      else:
        ""
    html &= fmt"""        <div class="file-row">
          <div class="file-name">
            <span class="file-icon">&#128193;</span>
            <a href="/api/archivist/v1/data/{cidStr}{parentPath}" class="parent-link">..</a>
          </div>
          <div class="file-cid">-</div>
          <div class="file-size">-</div>
        </div>
"""

  # Add sorted entries (directories first, then files)
  let sortedEntries = directory.sortedEntries()

  if sortedEntries.len == 0:
    html &= """        <div class="empty-dir">This directory is empty</div>
"""
  else:
    for entry in sortedEntries:
      let
        entryCidStr = $entry.cid
        entryIcon = getFileIcon(entry)
        entryName = escapeHtml(entry.name)
        entrySize = formatSize(entry.size)
        entryLink = fmt"/api/archivist/v1/data/{entryCidStr}"
        displayName = if entry.isDirectory: entryName & "/" else: entryName

      html &= fmt"""        <div class="file-row">
          <div class="file-name">
            <span class="file-icon">{entryIcon}</span>
            <a href="{entryLink}">{displayName}</a>
          </div>
          <div class="file-cid">
            <a href="/api/archivist/v1/data/{entryCidStr}" title="{entryCidStr}">{truncateCid(entryCidStr)}</a>
          </div>
          <div class="file-size">{entrySize}</div>
        </div>
"""

  html &= fmt"""      </div>
    </div>
  </main>

  <footer>
    <div class="container">
      Served by <a href="https://archivist.storage">Archivist</a>
    </div>
  </footer>
</body>
</html>"""

  return html
