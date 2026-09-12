## Small, scoped permission policy for local tool execution.

import std/[json, os, strutils, tables]
import nimgent
import trust

type
  PermissionDecision* = enum
    pdAllowOnce
    pdAllowSession
    pdAllowProject
    pdDeny

  PermissionCheck* = enum
    pcAllow
    pcAsk
    pcDeny

  PermissionPolicy* = ref object
    workspace*: string
    projectPath*: string
    sessionAllows: Table[string, bool]
    projectAllows: Table[string, bool]

proc normalizedCommand*(command: string): string =
  command.splitWhitespace.join(" ")

proc commandFrom(call: ContentBlock): string =
  if call.input.isNil or call.input.kind != JObject: return ""
  call.input.getOrDefault("command").getStr

proc permissionKey*(call: ContentBlock): string =
  if call.name == "bash":
    return "bash:" & normalizedCommand(commandFrom(call))
  "tool:" & call.name

proc permissionDescription*(call: ContentBlock): string =
  if call.name == "bash":
    return normalizedCommand(commandFrom(call))
  call.name

proc dangerousCommand(command: string): bool =
  let value = " " & command.toLowerAscii & " "
  for marker in [" rm ", " git reset ", " git clean ", " git checkout -- ",
                 " git restore ", " sudo ", " curl ", " wget ", " ssh ",
                 " scp ", " chmod ", " chown ", " kill ", " pkill ",
                 " dd ", " mkfs ", " shutdown ", " reboot "]:
    if marker in value: return true
  false

proc canRemember*(call: ContentBlock): bool =
  call.name != "bash" or not dangerousCommand(commandFrom(call))

proc projectPermissionPath(workspace: string): string =
  workspace / ".nimlet" / "permissions.json"

proc loadAllows(node: JsonNode): Table[string, bool] =
  result = initTable[string, bool]()
  if node.isNil or node.kind != JArray: return
  for item in node:
    if item.kind == JString:
      result[item.getStr] = true

proc newPermissionPolicy*(workspace: string): PermissionPolicy =
  result = PermissionPolicy(
    workspace: expandFilename(workspace),
    projectPath: projectPermissionPath(expandFilename(workspace)),
    sessionAllows: initTable[string, bool](),
    projectAllows: initTable[string, bool]())
  if not projectResourcesTrusted(result.workspace): return
  if not fileExists(result.projectPath): return
  try:
    let doc = parseJson(readFile(result.projectPath))
    result.projectAllows = loadAllows(doc.getOrDefault("allow"))
  except CatchableError:
    discard

proc workspaceTool(name: string): bool =
  name in ["read", "grep", "glob", "read_skill", "edit", "write", "ask_user"]

proc check*(policy: PermissionPolicy, call: ContentBlock): PermissionCheck =
  if policy.isNil: return pcAsk
  if call.name.len == 0: return pcDeny
  if workspaceTool(call.name): return pcAllow
  let key = permissionKey(call)
  if call.name == "bash" and dangerousCommand(commandFrom(call)):
    return pcAsk
  if key in policy.sessionAllows or key in policy.projectAllows:
    return pcAllow
  pcAsk

proc persistProject(policy: PermissionPolicy) =
  var doc = newJObject()
  var allows = newJArray()
  for key in policy.projectAllows.keys:
    allows.add %key
  doc["allow"] = allows
  createDir(policy.projectPath.parentDir)
  writeFile(policy.projectPath, pretty(doc) & "\n")

proc remember*(policy: PermissionPolicy, call: ContentBlock,
               decision: PermissionDecision) =
  if policy.isNil or not canRemember(call): return
  let key = permissionKey(call)
  case decision
  of pdAllowSession:
    policy.sessionAllows[key] = true
  of pdAllowProject:
    policy.projectAllows[key] = true
    persistProject(policy)
  else:
    discard

proc clearProject*(policy: PermissionPolicy) =
  if policy.isNil: return
  policy.projectAllows.clear()
  persistProject(policy)

proc describe*(policy: PermissionPolicy): string =
  if policy.isNil: return "Permission grants: (default)"
  result = "Permission grants:"
  if policy.sessionAllows.len == 0 and policy.projectAllows.len == 0:
    result.add "\n  (none)"
    return
  for key in policy.projectAllows.keys:
    result.add "\n  project  " & key
  for key in policy.sessionAllows.keys:
    result.add "\n  session  " & key
