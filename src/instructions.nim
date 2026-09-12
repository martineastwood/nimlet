## Instruction discovery: global user defaults, then AGENTS.md from the
## repository root toward the workspace. More-specific files appear later
## in the stable system prefix. Walk stops at the git root.

import std/[algorithm, os, strutils, times]
import config
import trust

const MaxInstructionBytes = 64 * 1024

type
  InstructionCacheEntry = object
    paths: seq[string]
    mtimes: seq[Time]
    text: string

  SystemPromptCacheEntry = object
    paths: seq[string]
    mtimes: seq[Time]
    replacementFound: bool
    replacement: string
    appended: string

var instructionCache: seq[InstructionCacheEntry]
var systemPromptCache: seq[SystemPromptCacheEntry]

proc contextFilePath(path: string): string =
  let override = path / "AGENTS.override.md"
  if fileExists(override): return override
  let agents = path / "AGENTS.md"
  if fileExists(agents): return agents
  let claude = path / "CLAUDE.md"
  if fileExists(claude): return claude

proc globalAgentsPath*(): string =
  contextFilePath(nimletConfigDir())

proc isRepositoryRoot(path: string): bool =
  fileExists(path / ".git") or dirExists(path / ".git")

proc projectInstructionPaths(workspace: string): seq[string] =
  var current = expandFilename(workspace)
  while true:
    let path = contextFilePath(current)
    if path.len > 0:
      result.add path
    if isRepositoryRoot(current):
      break
    let parent = current.parentDir
    if parent == current:
      break
    current = parent
  result.reverse()

proc instructionPaths*(workspace: string, globalPath = ""): seq[string] =
  ## `globalPath` empty → `<config>/nimlet/AGENTS.md`. Missing files are skipped.
  let global = if globalPath.len > 0: globalPath
               else: contextFilePath(nimletConfigDir())
  if global.len > 0 and fileExists(global):
    result.add global
  result.add projectInstructionPaths(workspace)

proc boundedInstruction(path: string): string =
  try:
    result = readFile(path)
  except CatchableError:
    return ""
  if result.len > MaxInstructionBytes:
    result = result[0 ..< MaxInstructionBytes] &
      "\n\n[instructions truncated]\n"

proc instructionMtimes(paths: openArray[string]): seq[Time] =
  for path in paths:
    if fileExists(path):
      try:
        result.add getLastModificationTime(path)
      except CatchableError:
        result.add Time()
    else:
      result.add Time()

proc sameInstructionCache(entry: InstructionCacheEntry,
                          paths: seq[string], mtimes: seq[Time]): bool =
  entry.paths == paths and entry.mtimes == mtimes

proc formatInstructions(workspace, global: string,
                        paths: openArray[string]): string =
  if paths.len == 0:
    return
  result = "Project instructions. Apply less-specific files before more-specific files:\n"
  for path in paths:
    let content = boundedInstruction(path)
    if content.len == 0:
      continue
    let label = if path == global: "global" else: relativePath(path, workspace)
    result.add "\n<file path=\"" & label & "\">\n"
    result.add content
    if not content.endsWith("\n"):
      result.add "\n"
    result.add "</file>\n"

proc clearInstructionCache*() =
  instructionCache.setLen(0)
  systemPromptCache.setLen(0)

proc loadProjectInstructions*(workspace: string, globalPath = ""): string =
  let paths = instructionPaths(workspace, globalPath)
  if paths.len == 0:
    return ""
  let global = if globalPath.len > 0: globalPath
               else: globalAgentsPath()
  let mtimes = instructionMtimes(paths)
  for entry in instructionCache:
    if entry.sameInstructionCache(paths, mtimes):
      return entry.text
  result = formatInstructions(workspace, global, paths)
  instructionCache.add InstructionCacheEntry(paths: paths, mtimes: mtimes,
    text: result)

proc systemPromptPaths(workspace: string): tuple[replacement: string,
                                                 appended: seq[string]] =
  let root = if dirExists(workspace): expandFilename(workspace) else: workspace
  let globalDir = nimletConfigDir()
  let projectDir = root / ".nimlet"
  let projectReplacement = projectDir / "SYSTEM.md"
  let globalReplacement = globalDir / "SYSTEM.md"
  result.replacement = if projectResourcesTrusted(root) and fileExists(projectReplacement): projectReplacement
                       elif fileExists(globalReplacement): globalReplacement
                       else: ""
  let globalAppend = globalDir / "APPEND_SYSTEM.md"
  let projectAppend = projectDir / "APPEND_SYSTEM.md"
  if fileExists(globalAppend): result.appended.add globalAppend
  if projectResourcesTrusted(root) and fileExists(projectAppend):
    result.appended.add projectAppend

proc loadSystemPrompt*(workspace: string): tuple[replacementFound: bool,
                                                   replacement, appended: string] =
  let paths = systemPromptPaths(workspace)
  var cachePaths = @[paths.replacement]
  cachePaths.add paths.appended
  let mtimes = instructionMtimes(cachePaths)
  for entry in systemPromptCache:
    if entry.paths == cachePaths and entry.mtimes == mtimes:
      return (entry.replacementFound, entry.replacement, entry.appended)
  result.replacementFound = paths.replacement.len > 0
  if result.replacementFound:
    result.replacement = boundedInstruction(paths.replacement)
  for path in paths.appended:
    let content = boundedInstruction(path)
    if content.len == 0: continue
    if result.appended.len > 0: result.appended.add "\n"
    result.appended.add content
  systemPromptCache.add SystemPromptCacheEntry(paths: cachePaths,
    mtimes: mtimes, replacementFound: result.replacementFound,
    replacement: result.replacement, appended: result.appended)

proc scopedInstructionPaths*(workspace, target: string): seq[string] =
  ## Find AGENTS.md files below the workspace that apply to a read target.
  let root = expandFilename(workspace)
  var current = expandFilename(if target.isAbsolute: target else: workspace / target)
  if fileExists(current):
    current = current.parentDir
  while current.len > 0 and current != root and
      current.startsWith(root & DirSep):
    let path = contextFilePath(current)
    if path.len > 0: result.add path
    let parent = current.parentDir
    if parent == current: break
    current = parent
  result.reverse()

proc loadScopedInstructions*(workspace, target: string,
                             skip: openArray[string] = []): string =
  var paths = scopedInstructionPaths(workspace, target)
  for i in countdown(paths.high, 0):
    if paths[i] in skip:
      paths.delete(i)
  if paths.len == 0:
    return
  result = "Instructions for the requested path:\n"
  for path in paths:
    let content = boundedInstruction(path)
    if content.len == 0: continue
    result.add "\n<file path=\"" & relativePath(path, workspace) & "\">\n"
    result.add content
    if not content.endsWith("\n"): result.add "\n"
    result.add "</file>\n"
