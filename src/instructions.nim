## Instruction discovery: global user defaults, then AGENTS.md from the
## repository root toward the workspace. More-specific files appear later
## in the stable system prefix. Walk stops at the git root.

import std/[algorithm, os, strutils]
import config

const MaxInstructionBytes = 64 * 1024

proc globalAgentsPath*(): string =
  nimletConfigDir() / "AGENTS.md"

proc isRepositoryRoot(path: string): bool =
  fileExists(path / ".git") or dirExists(path / ".git")

proc projectInstructionPaths(workspace: string): seq[string] =
  var current = expandFilename(workspace)
  while true:
    let path = current / "AGENTS.md"
    if fileExists(path):
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
  let global = if globalPath.len > 0: globalPath else: globalAgentsPath()
  if fileExists(global):
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

proc loadProjectInstructions*(workspace: string, globalPath = ""): string =
  let paths = instructionPaths(workspace, globalPath)
  if paths.len == 0:
    return ""
  let global = if globalPath.len > 0: globalPath else: globalAgentsPath()
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
