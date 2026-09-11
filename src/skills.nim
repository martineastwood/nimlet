## Passive, Markdown-based skills.
##
## Startup only reads a small metadata prefix. The complete SKILL.md is
## returned through the read_skill tool when the model asks for it.

import std/[algorithm, asyncdispatch, json, os, strutils]
import config
import nimgent
import tools/tool

const MaxSkillBytes = 100_000

type
  SkillMetadata* = object
    name*: string
    description*: string
    path*: string

  SkillCacheEntry = object
    workspace: string
    skills: seq[SkillMetadata]

var skillCache: seq[SkillCacheEntry]

proc readMetadata(path: string): SkillMetadata =
  result.path = path
  result.name = path.parentDir.splitPath.tail
  var file: File
  if not open(file, path):
    return
  defer: file.close()

  var mode = 0 ## 0 = undecided, 1 = frontmatter, 2 = body
  var lineNumber = 0
  while lineNumber < 64:
    var line: string
    if not file.readLine(line):
      break
    inc lineNumber
    let stripped = line.strip
    if lineNumber == 1:
      if stripped == "---":
        mode = 1
        continue
      mode = 2
    if mode == 1:
      if stripped == "---":
        mode = 2
        continue
      let colon = stripped.find(':')
      if colon > 0:
        let key = stripped[0 ..< colon].strip.toLowerAscii
        let value = if colon + 1 < stripped.len:
          unquote(stripped[colon + 1 .. ^1])
        else:
          ""
        if key == "name":
          result.name = value
        elif key == "description":
          result.description = value
    elif result.description.len == 0 and stripped.len > 0 and
         not stripped.startsWith("#"):
      result.description = stripped

proc discoverSkillsUncached(workspace: string): seq[SkillMetadata] =
  ## Later roots override the same skill name: global → `.agent` → `.nimlet`.
  for dir in collectPluginDirs(workspace, "skills", "SKILL.md"):
    let skill = readMetadata(dir / "SKILL.md")
    if skill.name.len > 0:
      result.overrideNamed(skill)
  result.sort(proc(a, b: SkillMetadata): int =
    let byName = cmp(a.name.toLowerAscii, b.name.toLowerAscii)
    if byName != 0: byName else: cmp(a.path, b.path))

proc discoverSkills*(workspace: string): seq[SkillMetadata] =
  let key = if dirExists(workspace): expandFilename(workspace) else: workspace
  for entry in skillCache:
    if entry.workspace == key:
      return entry.skills
  result = discoverSkillsUncached(workspace)
  skillCache.add SkillCacheEntry(workspace: key, skills: result)

proc clearSkillCache*() =
  skillCache.setLen(0)

proc skillMetadataPrompt*(workspace: string): string =
  let skills = discoverSkills(workspace)
  if skills.len == 0:
    return ""
  result = "Available skills (use read_skill with the skill name to load one):\n"
  for skill in skills:
    result.add "- " & skill.name
    if skill.description.len > 0:
      result.add ": " & skill.description
    result.add "\n"

proc loadSkill*(workspace, name: string):
                 tuple[ok: bool, content: string, err: string] =
  if name.strip.len == 0:
    return (false, "", "skill name must not be empty")
  for skill in discoverSkills(workspace):
    if skill.name.toLowerAscii == name.strip.toLowerAscii:
      try:
        result.content = readFile(skill.path)
      except CatchableError as e:
        return (false, "", "could not read skill: " & e.msg)
      if result.content.len > MaxSkillBytes:
        return (false, "", "skill is too large (maximum 100000 bytes)")
      result.ok = true
      return
  (false, "", "skill not found: " & name)

proc makeSkillTool*(workspace: string): (ToolDefinition, ToolProc) =
  let def = ToolDefinition(
    name: "read_skill",
    description: "Load a project's or user's passive SKILL.md by name.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Skill name from the available skills list."}
      },
      "required": ["name"]
    }
  )

  proc run(input: JsonNode): Future[ToolResult] {.async.} =
    if input.isNil or input.kind != JObject or "name" notin input:
      return ToolResult(output: "skill name is required", isError: true)
    let loaded = loadSkill(workspace, input["name"].getStr)
    if not loaded.ok:
      return ToolResult(output: loaded.err, isError: true)
    return ToolResult(output: "Skill: " & input["name"].getStr & "\n\n" &
      loaded.content, isError: false)

  (def, run)
