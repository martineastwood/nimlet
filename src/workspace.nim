## Workspace boundary enforcement and file helpers shared by the file tools.

import std/[os, osproc, streams, strutils, algorithm]

type
  Workspace* = object
    root*: string

  WorkspaceError* = object of CatchableError

proc initWorkspace*(root: string): Workspace =
  Workspace(root: expandFilename(root))

proc hashContent*(content: string): string =
  ## FNV-1a version identifier. It only needs to detect concurrent edits, not
  ## resist an attacker, so avoid a crypto dependency in the small binary.
  var hash = 14695981039346656037'u64
  for ch in content:
    hash = (hash xor uint64(ord(ch))) * 1099511628211'u64
  toHex(hash, 16).toLowerAscii()

proc resolve*(ws: Workspace, path: string): string =
  ## Resolve a tool-supplied path against the workspace root and reject
  ## anything that escapes it. Symlinks are resolved before the check so a link
  ## inside the workspace cannot be used to reach outside it.
  if path.len == 0:
    raise newException(WorkspaceError, "path must not be empty")

  var abs = if path.isAbsolute: path else: ws.root / path
  abs = abs.normalizedPath

  # expandFilename requires the file to exist; for new files check the closest
  # existing ancestor instead.
  var probe = abs
  var suffix: seq[string] = @[]
  while probe.len > 0 and not fileExists(probe) and not dirExists(probe):
    let (parent, name) = probe.splitPath
    if parent == probe or name.len == 0: break
    suffix.add name
    probe = parent

  var real: string
  if probe.len > 0 and (fileExists(probe) or dirExists(probe)):
    real = expandFilename(probe)
    for i in countdown(suffix.high, 0):
      real = real / suffix[i]
  else:
    real = abs

  let root = ws.root.normalizedPath
  if real != root and not real.startsWith(root & DirSep):
    raise newException(WorkspaceError,
      "path is outside the workspace: " & path)
  real

proc relative*(ws: Workspace, path: string): string =
  try: relativePath(path, ws.root) except CatchableError: path

proc writeFileAtomic*(path, content: string) =
  ## Write via a temporary file in the same directory, then rename, so readers
  ## never observe a partially written file.
  let dir = path.parentDir
  if dir.len > 0: createDir(dir)
  let tmp = path & ".nimlet-tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, content)
    if fileExists(path):
      # Preserve the existing permission bits.
      setFilePermissions(tmp, getFilePermissions(path))
    moveFile(tmp, path)
  except CatchableError as e:
    removeFile(tmp)
    raise e

const
  mentionFileCap* = 50
  mentionDirCap = 200
  walkFileCap = 8_000
  skipDirNames = [".git", "node_modules", "nimbledeps", "nimcache", "dist",
                  "build", ".cache", "target", ".next", ".turbo"]

proc canonRel*(path: string): string =
  path.replace('\\', '/')

proc globMatchAt(s: string, si: int, p: string, pi: int): bool =
  if pi >= p.len: return si >= s.len
  if p[pi] == '*' and pi + 1 < p.len and p[pi + 1] == '*':
    var n = pi + 2
    if n < p.len and p[n] == '/': inc n
    if globMatchAt(s, si, p, n): return true
    var i = si
    while i < s.len:
      inc i
      if globMatchAt(s, i, p, n): return true
    return false
  if p[pi] == '*':
    if globMatchAt(s, si, p, pi + 1): return true
    var i = si
    while i < s.len and s[i] != '/':
      inc i
      if globMatchAt(s, i, p, pi + 1): return true
    return false
  if si >= s.len: return false
  if p[pi] == '?' or p[pi] == s[si]:
    return globMatchAt(s, si + 1, p, pi + 1)
  false

proc globMatch*(path, pattern: string): bool =
  ## `*` is one path segment, `**` is any depth, `?` is one character.
  if pattern.len == 0: return false
  globMatchAt(path.canonRel, 0, pattern.replace('\\', '/'), 0)

proc gitTrackedFiles(root: string): seq[string] =
  if not dirExists(root / ".git"):
    return
  var p: Process
  try:
    p = startProcess("git", workingDir = root,
      args = ["ls-files", "-co", "--exclude-standard", "--", "."],
      options = {poUsePath, poStdErrToStdOut})
  except CatchableError:
    return
  defer: p.close()
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    return
  for line in outp.splitLines:
    let rel = line.strip.canonRel
    if rel.len == 0: continue
    if fileExists(root / rel):
      result.add rel

proc walkWorkspaceFiles(root: string): seq[string] =
  var stack: seq[tuple[dir, rel: string]] = @[(root, "")]
  while stack.len > 0:
    let (dir, rel) = stack.pop()
    for kind, path in walkDir(dir):
      if result.len >= walkFileCap: return
      let name = path.extractFilename
      if kind == pcDir:
        if name in skipDirNames: continue
        stack.add (path, if rel.len == 0: name else: rel / name)
      elif kind == pcFile:
        result.add (if rel.len == 0: name else: rel / name).canonRel

proc listWorkspaceFiles*(root: string): seq[string] =
  ## Git-tracked + untracked (honoring gitignore) when `root` is a repo.
  ## Otherwise a bounded directory walk. No cache — callers are grep/glob
  ## and @-mentions (already keyed in the interactive UI).
  result = gitTrackedFiles(root)
  if result.len == 0 and not dirExists(root / ".git"):
    result = walkWorkspaceFiles(root)

proc mentionDirsOf(files: seq[string]): seq[string] =
  ## Unique parent folders of `files`, deepest first, as `dir/` entries.
  var seen: seq[string]
  for f in files:
    var dir = f.parentDir
    while dir.len > 0 and dir != ".":
      let entry = dir & "/"          ## trailing slash marks a folder entry
      if entry notin seen:
        seen.add entry
        result.add entry
      dir = dir.parentDir

proc delItem(items: var seq[string], item: string) =
  let i = items.find(item)
  if i >= 0: items.delete(i)

proc suggestMentionFiles*(root, query: string, cap = mentionFileCap): seq[string] =
  let q = query.toLowerAscii
  let files = listWorkspaceFiles(root)
  var paths = files
  for d in mentionDirsOf(files):    ## folders are suggestions too (@examples/)
    paths.add d
  paths.sort()
  if q.len > 0:
    paths.delItem(q)                ## completing "@src/" should not re-suggest itself
  var seen: seq[string]
  for f in paths:
    if result.len >= cap: break
    let base = f.extractFilename.toLowerAscii
    if q.len == 0 or base.startsWith(q):
      let mention = "@" & f
      var dup = false
      for x in seen:
        if x == mention: dup = true
      if not dup:
        seen.add mention
        result.add mention
  if q.len == 0 or result.len >= cap: return
  for f in paths:
    if result.len >= cap: return
    if q notin f.toLowerAscii: continue
    let mention = "@" & f
    var dup = false
    for x in seen:
      if x == mention: dup = true
    if not dup:
      seen.add mention
      result.add mention

proc mentionDirListing*(root, dir: string): string =
  ## Bounded recursive listing attached for an @folder mention. Skips the same
  ## junk directories as the workspace walk and caps the entry count.
  var stack: seq[string] = @[dir]
  var count = 0
  while stack.len > 0:
    let d = stack.pop()
    for kind, path in walkDir(d):
      let name = path.extractFilename
      if kind == pcDir:
        if name in skipDirNames: continue
      inc count
      if count > mentionDirCap:
        result.add "…\n"
        return
      let rel = relativePath(path, root).canonRel
      result.add rel & (if kind == pcDir: "/" else: "") & "\n"
      if kind == pcDir: stack.add path
