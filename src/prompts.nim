## File-backed prompt templates. The filename is the slash command name.

import std/[algorithm, os, strutils]
import config

const MaxPromptBytes = 100_000

type PromptTemplate* = object
  name*: string
  description*: string
  body*: string
  path*: string

proc parseTemplate(path: string): PromptTemplate =
  result.name = path.splitFile.name
  result.path = path
  let text = readFile(path)
  if text.len > MaxPromptBytes: return
  let lines = text.splitLines
  var bodyAt = 0
  if lines.len > 0 and lines[0].strip == "---":
    bodyAt = 1
    while bodyAt < lines.len and lines[bodyAt].strip != "---":
      let line = lines[bodyAt]
      let colon = line.find(':')
      if colon > 0 and line[0 ..< colon].strip.toLowerAscii == "description":
        result.description = unquote(line[colon + 1 .. ^1].strip)
      inc bodyAt
    if bodyAt < lines.len: inc bodyAt
  result.body = lines[bodyAt .. ^1].join("\n").strip
  if result.description.len == 0:
    for line in result.body.splitLines:
      if line.strip.len > 0:
        result.description = line.strip
        break

proc discoverPrompts*(workspace: string): seq[PromptTemplate] =
  ## Non-recursive; later roots override the same name.
  for root in pluginRoots(workspace, "prompts"):
    if not dirExists(root): continue
    var paths: seq[string]
    for kind, path in walkDir(root):
      if kind == pcFile and path.toLowerAscii.endsWith(".md"): paths.add path
    paths.sort()
    for path in paths:
      let prompt = parseTemplate(path)
      if prompt.name.len > 0 and prompt.body.len > 0:
        result.overrideNamed(prompt)
  result.sort(proc(a, b: PromptTemplate): int =
    cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc loadPrompt*(workspace, name: string): tuple[ok: bool, prompt: PromptTemplate] =
  for prompt in discoverPrompts(workspace):
    if prompt.name.toLowerAscii == name.toLowerAscii:
      return (true, prompt)

proc expandPrompt*(workspace, name, arguments: string): string =
  let loaded = loadPrompt(workspace, name)
  if not loaded.ok: return
  loaded.prompt.body.replace("$ARGUMENTS", arguments).replace("$@", arguments)
