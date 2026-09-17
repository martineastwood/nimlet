import std/[json, os, strutils]
import nimterm/theme

const tokenNames = [
  "accent", "success", "error", "warning", "code", "muted", "dim", "text",
  "heading", "model", "panelBg", "selectedBg", "selectedFg"]

var activeDepth = cd256

proc setToken(spec: var ThemeSpec, key, value: string) =
  case key
  of "accent": spec.accent = value
  of "success": spec.success = value
  of "error": spec.error = value
  of "warning": spec.warning = value
  of "code": spec.code = value
  of "muted": spec.muted = value
  of "dim": spec.dim = value
  of "text": spec.text = value
  of "heading": spec.heading = value
  of "model": spec.model = value
  of "panelBg": spec.panelBg = value
  of "selectedBg": spec.selectedBg = value
  of "selectedFg": spec.selectedFg = value
  else: discard

proc parseThemeJson*(doc: JsonNode): tuple[ok: bool, spec: ThemeSpec, err: string] =
  if doc.isNil or doc.kind != JObject:
    return (false, ThemeSpec(), "theme must be a JSON object")
  let name = if "name" in doc and doc["name"].kind == JString:
    doc["name"].getStr.strip else: ""
  if name.len == 0: return (false, ThemeSpec(), "theme name is required")
  if '/' in name: return (false, ThemeSpec(), "theme name must not contain '/'")
  if "colors" notin doc or doc["colors"].kind != JObject:
    return (false, ThemeSpec(), "theme colors object is required")
  var spec = ThemeSpec(name: name)
  var seen: seq[string]
  for key, node in doc["colors"]:
    if key notin tokenNames:
      return (false, ThemeSpec(), "unknown color token '" & key & "'")
    let value = case node.kind
      of JString: node.getStr
      of JInt: $node.getInt
      of JFloat: $node.getInt
      else: ""
    spec.setToken(key, value)
    seen.add key
  for key in tokenNames:
    if key notin seen:
      return (false, ThemeSpec(), "missing color token '" & key & "'")
  (true, spec, "")

proc discoverThemes(workspace, appDir, globalDir: string): seq[ThemeSpec] =
  var roots = @[(if globalDir.len > 0: globalDir else: getHomeDir() / appDir) / "themes"]
  if workspace.len > 0:
    roots.add (if dirExists(workspace): expandFilename(workspace) else: workspace) /
      appDir / "themes"
  for root in roots:
    if not dirExists(root): continue
    for kind, path in walkDir(root):
      if kind != pcFile or not path.endsWith(".json"): continue
      try:
        let loaded = parseThemeJson(parseJson(readFile(path)))
        if not loaded.ok: continue
        var replaced = false
        for i, spec in result:
          if spec.name.toLowerAscii == loaded.spec.name.toLowerAscii:
            result[i] = loaded.spec
            replaced = true
        if not replaced: result.add loaded.spec
      except CatchableError:
        discard

proc listThemeNames*(workspace = "", appDir = ".nimlet", globalDir = ""): seq[string] =
  result = @["auto", "dark", "light"]
  for spec in discoverThemes(workspace, appDir, globalDir):
    if spec.name.toLowerAscii notin result: result.add spec.name

proc findUserTheme*(name, workspace: string, appDir = ".nimlet",
                    globalDir = ""): tuple[ok: bool, spec: ThemeSpec, err: string] =
  for spec in discoverThemes(workspace, appDir, globalDir):
    if spec.name.toLowerAscii == name.toLowerAscii: return (true, spec, "")
  (false, ThemeSpec(), "unknown theme '" & name & "'")

proc compileNamedTheme*(name: string, depth: ColorDepth, workspace = "",
                        appDir = ".nimlet", globalDir = ""):
                        tuple[ok: bool, theme: Theme, err: string] =
  let builtin = compileBuiltinTheme(name, depth)
  if builtin.ok: return (true, builtin.theme, "")
  let user = findUserTheme(resolveThemeName(name), workspace, appDir, globalDir)
  if not user.ok: return (false, Theme(), user.err)
  (true, compileTheme(user.spec, depth), "")

proc applyTheme*(name: string, depth = activeDepth, workspace = "",
                 appDir = ".nimlet", globalDir = ""): string =
  let compiled = compileNamedTheme(name, depth, workspace, appDir, globalDir)
  if not compiled.ok: return compiled.err
  activeDepth = depth
  setTheme(compiled.theme)
  ""
