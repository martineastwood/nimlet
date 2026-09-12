## Project-local resource trust.
##
## Trust is deliberately separate from tool permissions: it decides whether
## project-supplied behavior and configuration are loaded at all.

import std/[algorithm, json, os, strutils]
import workspace

type
  TrustOverride* = enum
    trustDefault
    trustApprove
    trustDeny

  ProjectTrust* = object
    workspace*: string
    required*: bool
    trusted*: bool
    prompt*: bool
    resources*: seq[string]

var trustScopes: seq[tuple[workspace: string, trusted: bool]]

proc canonicalWorkspace*(workspace: string): string =
  let path = if workspace.len == 0: getCurrentDir()
             elif workspace.isAbsolute: workspace
             else: getCurrentDir() / workspace
  if dirExists(path): path.expandFilename else: path.normalizedPath

proc trustPath*(): string =
  getHomeDir() / ".nimlet" / "trust.json"

proc addFile(result: var seq[string], root, relative: string) =
  if fileExists(root / relative): result.add relative

proc addManifestDirs(result: var seq[string], root, relative, manifest: string) =
  let base = root / relative
  if not dirExists(base): return
  var paths: seq[string]
  for kind, path in walkDir(base):
    if kind == pcDir and fileExists(path / manifest):
      paths.add relativePath(path, root) / manifest
  paths.sort()
  result.add paths

proc addJsonFiles(result: var seq[string], root, relative: string) =
  let base = root / relative
  if not dirExists(base): return
  var paths: seq[string]
  for kind, path in walkDir(base):
    if kind == pcFile and path.toLowerAscii.endsWith(".json"):
      paths.add relativePath(path, root)
  paths.sort()
  result.add paths

proc addMarkdownFiles(result: var seq[string], root, relative: string) =
  let base = root / relative
  if not dirExists(base): return
  var paths: seq[string]
  for kind, path in walkDir(base):
    if kind == pcFile and path.toLowerAscii.endsWith(".md"):
      paths.add relativePath(path, root)
  paths.sort()
  result.add paths

proc projectTrustResources*(workspace: string): seq[string] =
  let root = canonicalWorkspace(workspace)
  for path in [".nimlet/config.json", ".nimlet/permissions.json",
               ".nimlet/SYSTEM.md", ".nimlet/APPEND_SYSTEM.md"]:
    result.addFile(root, path)
  result.addManifestDirs(root, ".agent/tools", "tool.json")
  result.addManifestDirs(root, ".nimlet/tools", "tool.json")
  result.addManifestDirs(root, ".agents/extensions", "extension.json")
  result.addManifestDirs(root, ".nimlet/extensions", "extension.json")
  for path in [".agent/skills", ".agents/skills", ".nimlet/skills"]:
    result.addManifestDirs(root, path, "SKILL.md")
  for path in [".agent/prompts", ".agents/prompts", ".nimlet/prompts"]:
    result.addMarkdownFiles(root, path)
  result.addJsonFiles(root, ".nimlet/themes")

proc projectResourcesTrusted*(workspace: string): bool =
  let key = canonicalWorkspace(workspace)
  for scope in trustScopes:
    if scope.workspace == key:
      return scope.trusted
  ## Library callers and tests historically loaded project resources directly.
  ## The application sets this explicitly before startup discovery.
  true

proc setProjectResourcesTrusted*(workspace: string, trusted: bool) =
  let key = canonicalWorkspace(workspace)
  for i in 0 ..< trustScopes.len:
    if trustScopes[i].workspace == key:
      trustScopes[i].trusted = trusted
      return
  trustScopes.add (key, trusted)

proc trustDoc(): JsonNode =
  if not fileExists(trustPath()): return newJObject()
  try:
    result = parseJson(readFile(trustPath()))
    if result.isNil or result.kind != JObject: result = newJObject()
  except CatchableError:
    result = newJObject()

proc savedTrust(workspace: string): tuple[found, trusted: bool] =
  let projects = trustDoc().getOrDefault("projects")
  if projects.isNil or projects.kind != JObject: return
  var current = canonicalWorkspace(workspace)
  while true:
    if current in projects and projects[current].kind == JBool:
      return (true, projects[current].getBool)
    let parent = current.parentDir
    if parent == current: break
    current = parent

proc saveProjectTrust*(workspace: string, trusted: bool) =
  var doc = trustDoc()
  if "projects" notin doc or doc["projects"].kind != JObject:
    doc["projects"] = newJObject()
  doc["projects"][canonicalWorkspace(workspace)] = %trusted
  writeFileAtomic(trustPath(), pretty(doc) & "\n")

proc resolveProjectTrust*(workspace: string,
                          override = trustDefault): ProjectTrust =
  result.workspace = canonicalWorkspace(workspace)
  result.resources = projectTrustResources(result.workspace)
  result.required = result.resources.len > 0
  if not result.required:
    result.trusted = true
    return
  case override
  of trustApprove:
    result.trusted = true
  of trustDeny:
    result.trusted = false
  of trustDefault:
    let saved = savedTrust(result.workspace)
    if saved.found:
      result.trusted = saved.trusted
    else:
      result.prompt = true
      result.trusted = false
