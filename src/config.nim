## JSON settings: global ~/.nimlet/config.json, overlay .nimlet/config.json.
## Credentials: private ~/.nimlet/auth.json.
## Known fields only on load (missing keys get defaults). Saves patch the
## write target in place.
##
## Plugin search roots (skills, tools, hooks) also live here: global
## `~/.nimlet`, then `.agent`, then `.nimlet`. Later wins by name.

import std/[algorithm, json, os, strutils, tables, uri]
import nimgent
from nimgent/providers/anthropic import anthropicEfforts, anthropicThinkingOptions
from nimgent/providers/openai import gatewayBase
import models_dev, compaction
import trust

const
  nimletVersion* = "0.1.1"
  ## The Gemini API key is exported under any of these names. nimlet accepts
  ## them all, preferring the first, so an existing key just works.
  googleApiKeyEnvs* = ["GEMINI_API_KEY", "GOOGLE_API_KEY",
    "GOOGLE_GENERATIVE_AI_API_KEY"]
  WiredProviders* = ["anthropic", "codex", "google", "hyper", "mistral", "openai",
    "opencode", "opencodezen", "openrouter"]

type
  AgentConfig* = object
    workspace*: string
    writePath*: string   ## project config if it exists, else global
    authPath*: string
    auth*: JsonNode      ## private provider credentials from auth.json
    sourcePaths*: seq[string]
    lastModels*: Table[string, string]
    provider*: string
    model*: string
    ## Merged default_model at load; `/model` updates `model` and the write file.
    defaultModel*: string
    theme*: string
    apiKeySource*: string
    apiKeyOverride*: string
    apiKeyOverrideProvider*: string
    endpoint*: string
    siteUrl*: string
    siteName*: string
    maxTokens*: int
    contextWindow*: int
    compactionEnabled*: bool
    reserveTokens*: int
    keepRecentTokens*: int
    thinking*: string
    steeringMode*: string
    followUpMode*: string
    webSearch*: bool  ## hosted web_search; only sent on supported providers
    requestTimeout*: int
    maxToolOutputBytes*: int
    sessionDir*: string
    keybindings*: JsonNode
    providers: JsonNode  ## merged `providers` object

const
  ThinkingLevels* = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
  QueueModes* = ["one-at-a-time", "all"]
  DefaultQueueMode* = "one-at-a-time"

proc guessContextWindow*(model: string): int =
  let m = model.toLowerAscii
  if "gemini" in m: return 1_048_576
  if "claude" in m: return 200_000
  if "gpt-5" in m or "gpt-4.1" in m: return 1_048_576
  if "gpt-4o" in m or "o1" in m or "o3" in m: return 200_000
  if "deepseek" in m: return 128_000
  if "qwen" in m: return 128_000
  if "mistral" in m or "devstral" in m or "codestral" in m:
    return 262_144
  128_000

proc effectiveContextWindow*(config: AgentConfig): int =
  if config.contextWindow > 0: return config.contextWindow
  let fromCatalog = lookupContextWindow(config.provider, config.model)
  if fromCatalog > 0: return fromCatalog
  guessContextWindow(config.model)

proc normalizeThinking*(value: string): string =
  let v = value.strip.toLowerAscii
  if v.len == 0: return ""
  if v in ThinkingLevels: return v
  raise newException(ValueError,
    "invalid thinking level '" & value & "' (use " & ThinkingLevels.join("|") & ")")

proc normalizeQueueMode*(value: string): string =
  let v = value.strip.toLowerAscii
  if v in QueueModes: return v
  raise newException(ValueError,
    "invalid queue mode '" & value & "' (use " & QueueModes.join("|") & ")")

proc snapToEfforts*(want: string, efforts: openArray[string]): string =
  ## Nearest canonical rung. Tie goes to the higher effort. `none` never snaps up.
  if want.len == 0: return ""
  for e in efforts:
    if e == want: return want
  if want == "none": return ""
  proc idx(s: string): int =
    result = -1
    for i, x in ThinkingLevels:
      if x == s: return i
  let wi = idx(want)
  if wi < 0: return ""
  var bestI = -1
  var bestD = 100
  for e in efforts:
    let ei = idx(e)
    if ei < 0: continue
    let d = abs(ei - wi)
    if bestI < 0 or d < bestD or (d == bestD and ei > bestI):
      bestD = d
      bestI = ei
      result = e

proc thinkingChoices*(provider, model: string): seq[string] =
  ## `/thinking` menu for this model. Catalog miss → full ladder.
  if provider.toLowerAscii == "anthropic":
    let efforts = anthropicEfforts(model)
    if efforts.len > 0:
      return if model.toLowerAscii.startsWith("claude-fable-5"): efforts
             else: @["none"] & efforts
  let caps = lookupReasoningCaps(provider, model)
  if not caps.known:
    for x in ThinkingLevels: result.add x
    return
  if not caps.reasoning:
    return
  result.add "none"
  if caps.efforts.len > 0:
    for x in ThinkingLevels:
      if x == "none": continue
      for e in caps.efforts:
        if e == x:
          result.add x
          break
    return
  if caps.toggle:
    result.add "high"
    return
  if caps.budgetTokens:
    for x in ThinkingLevels:
      if x != "none": result.add x

type
  ThinkingPlan = object
    label: string
    options: JsonNode

proc resolveThinking(provider, model, want: string): ThinkingPlan =
  result.options = newJObject()
  if want.len == 0: return
  let p = provider.toLowerAscii
  if p == "anthropic" and anthropicEfforts(model).len > 0:
    let required = want == "none" and model.toLowerAscii.startsWith("claude-fable-5")
    result.options = anthropicThinkingOptions(model, if required: "low" else: want)
    if required:
      result.label = "low (thinking required)"
      return
    result.label = if want == "none": "off"
                   else: result.options["output_config"]["effort"].getStr
    return
  let caps = lookupReasoningCaps(provider, model)

  if caps.known and not caps.reasoning:
    return
  if caps.known and caps.efforts.len > 0:
    let snapped = snapToEfforts(want, caps.efforts)
    if snapped.len == 0 or snapped == "none":
      result.label = "off"
      return
    result.label = snapped
    result.options = thinkingOptions(p, snapped)
    return
  if caps.known and caps.toggle:
    if want == "none":
      result.label = "off"
    else:
      result.label = "on"
      result.options = thinkingOptions(p, want, twToggle)
    return
  if caps.known and caps.budgetTokens:
    if want == "none":
      result.label = "off"
      return
    result.label = want
    result.options = thinkingOptions(p, want, twMaxTokens)
    return
  if caps.known:
    return
  if want == "none":
    result.label = "off"
    return
  result.label = want
  result.options = thinkingOptions(p, want)

proc webSearchAvailable*(config: AgentConfig): bool =
  ## Hosted search needs a provider that runs the search itself: the first-party
  ## ones, or Zen's Gemini models, which nimlet sends on the native wire. The
  ## endpoint clause mirrors the router: an unmappable base stays on Chat.
  let p = config.provider.toLowerAscii
  p in ["openai", "anthropic", "google"] or
    (p == "opencodezen" and gatewayBase(config.endpoint).len > 0 and
      modelApiPackage(p, config.model) == "@ai-sdk/google")

proc webSearchActive*(config: AgentConfig): bool =
  config.webSearch and webSearchAvailable(config)

proc webSearchStatus*(config: AgentConfig): string =
  if webSearchActive(config): "on"
  elif config.webSearch: "on (this provider or model has no hosted search)"
  else: "off"

proc thinkingStatus*(config: AgentConfig): string =
  let want = if config.thinking.len == 0: "" else: normalizeThinking(config.thinking)
  resolveThinking(config.provider, config.model, want).label

proc unquote*(value: string): string =
  result = value.strip
  if result.len >= 2 and ((result[0] == '"' and result[^1] == '"') or
                          (result[0] == '\'' and result[^1] == '\'')):
    result = result[1 .. ^2]

proc nimletConfigDir*(): string =
  getHomeDir() / ".nimlet"

proc pluginRoots*(workspace, folder: string): seq[string] =
  ## Search order: global → `.agent` → `.nimlet`. Later wins by name.
  result.add nimletConfigDir() / folder
  let root = if dirExists(workspace): expandFilename(workspace) else: workspace
  if projectResourcesTrusted(root):
    result.add root / ".agent" / folder
    result.add root / ".nimlet" / folder

proc collectPluginDirs*(workspace, folder, manifest: string): seq[string] =
  ## Dirs that contain `manifest`, later roots last.
  for root in pluginRoots(workspace, folder):
    if not dirExists(root):
      continue
    var dirs: seq[string]
    for kind, path in walkDir(root):
      if kind == pcDir and fileExists(path / manifest):
        dirs.add path
    dirs.sort()
    result.add dirs

proc overrideNamed*[T](items: var seq[T], item: T) =
  ## Replace the first item with the same case-insensitive `.name`, or append.
  for i in 0 ..< items.len:
    if items[i].name.toLowerAscii == item.name.toLowerAscii:
      items[i] = item
      return
  items.add item

proc apiKeyEnvCandidates*(provider: string): seq[string] =
  ## Environment variables that can hold this provider's key, best first.
  case provider.toLowerAscii
  of "openrouter": @["OPENROUTER_API_KEY"]
  of "openai": @["OPENAI_API_KEY"]
  of "anthropic": @["ANTHROPIC_API_KEY"]
  of "hyper": @["HYPER_API_KEY"]
  of "google": @googleApiKeyEnvs
  of "mistral": @["MISTRAL_API_KEY"]
  of "opencode", "opencodezen": @["OPENCODE_API_KEY"]
  else: @[]

proc defaultApiKeyEnv*(provider: string): string =
  ## The name to suggest: what a fresh setup exports, and how `/doctor` reports
  ## the provider when none of the accepted variables is set.
  let candidates = apiKeyEnvCandidates(provider)
  if candidates.len > 0: candidates[0] else: ""

proc defaultApiKeySource*(provider: string): string =
  let name = defaultApiKeyEnv(provider)
  if name.len > 0: "{env:" & name & "}" else: ""

proc apiKeyEnv*(provider: string): string =
  ## Whichever accepted variable actually holds a key, or "" when none does.
  for name in apiKeyEnvCandidates(provider):
    if getEnv(name).len > 0: return name

proc defaultEndpoint*(provider: string): string =
  case provider.toLowerAscii
  of "openrouter": "https://openrouter.ai/api/v1/chat/completions"
  of "openai": "https://api.openai.com/v1/responses"
  of "anthropic": "https://api.anthropic.com/v1/messages"
  of "hyper": "https://hyper.charm.land/v1/chat/completions"
  of "google": "https://generativelanguage.googleapis.com/v1beta"
  of "mistral": "https://api.mistral.ai/v1/chat/completions"
  of "opencode": "https://opencode.ai/zen/go/v1/chat/completions"
  of "opencodezen": "https://opencode.ai/zen/v1/chat/completions"
  else: ""

proc defaultProviderModel*(provider: string): string =
  case provider.toLowerAscii
  of "openrouter": "deepseek/deepseek-v4-flash-0731"
  of "openai": "gpt-5"
  of "hyper": "deepseek-v4-flash"
  of "anthropic": "claude-sonnet-4-6"
  of "google": "gemini-3.5-flash-lite"
  of "mistral": "mistral-vibe-cli-with-tools"
  of "opencode": "deepseek-v4.1-flash"
  of "opencodezen": "deepseek-v4-flash"
  of "codex": "gpt-5"
  else: ""

proc loadJsonFile(path: string): JsonNode =
  if path.len == 0 or not fileExists(path):
    return newJObject()
  try:
    result = parseJson(readFile(path))
    if result.isNil or result.kind != JObject:
      result = newJObject()
  except CatchableError:
    result = newJObject()

proc overlay(base, over: JsonNode): JsonNode =
  if over.isNil or over.kind != JObject:
    return if base.isNil: newJObject() else: copy(base)
  if base.isNil or base.kind != JObject:
    return copy(over)
  result = copy(base)
  for k, v in over:
    if v.kind == JObject and k in result and result[k].kind == JObject:
      result[k] = overlay(result[k], v)
    else:
      result[k] = copy(v)

proc jobj(n: JsonNode, key: string): JsonNode =
  if n.isNil or n.kind != JObject or key notin n: return newJObject()
  let v = n[key]
  if v.kind == JObject: v else: newJObject()

proc jstr(n: JsonNode, key: string, fallback = ""): string =
  if n.isNil or n.kind != JObject or key notin n: return fallback
  let v = n[key]
  case v.kind
  of JString: v.getStr
  of JInt: $v.getInt
  else: fallback

proc jint(n: JsonNode, key: string, fallback: int): int =
  if n.isNil or n.kind != JObject or key notin n: return fallback
  let v = n[key]
  case v.kind
  of JInt: v.getInt
  of JString:
    try: parseInt(v.getStr)
    except ValueError: fallback
  else: fallback

proc jbool(n: JsonNode, key: string, fallback: bool): bool =
  if n.isNil or n.kind != JObject or key notin n: return fallback
  let v = n[key]
  case v.kind
  of JBool: v.getBool
  of JString: v.getStr.toLowerAscii notin ["0", "false", "no", "off"]
  of JInt: v.getInt != 0
  else: fallback

proc providerBlock(config: AgentConfig, provider: string): JsonNode =
  jobj(config.providers, provider)

proc providerOptions*(config: AgentConfig): JsonNode =
  ## Native API options for the active provider; explicit /thinking wins.
  result = newJObject()
  mergeRequestOptions(result, config.providerBlock(config.provider).getOrDefault("options"))
  result = result.copy
  let want = if config.thinking.len == 0: "" else: normalizeThinking(config.thinking)
  if want.len == 0: return
  # Clear configured thinking even when the selected level resolves to omission
  # (e.g. `none` or a model without reasoning support).
  for key in ["reasoning", "reasoning_effort", "thinking"]:
    if result.hasKey(key): result.delete(key)
  if result.hasKey("output_config") and result["output_config"].kind == JObject:
    if result["output_config"].hasKey("effort"): result["output_config"].delete("effort")
    if result["output_config"].len == 0: result.delete("output_config")
  result = overlay(result, resolveThinking(config.provider, config.model, want).options)

proc authEntry(config: AgentConfig, provider: string): JsonNode =
  if config.auth.isNil or config.auth.kind != JObject or provider notin config.auth:
    return newJObject()
  let entry = config.auth[provider]
  if entry.kind == JObject: entry else: newJObject()

proc authType(config: AgentConfig, provider: string): string =
  jstr(config.authEntry(provider), "type").toLowerAscii

proc fillProvider*(config: var AgentConfig, provider: string) =
  let p = provider.toLowerAscii
  config.provider = p
  let settings = config.providerBlock(p)
  config.apiKeySource = if config.authType(p).len > 0:
    "auth " & config.authPath
  else:
    defaultApiKeySource(p)
  config.endpoint = jstr(settings, "endpoint")
  if config.endpoint.len == 0:
    config.endpoint = defaultEndpoint(p)
  config.siteUrl = jstr(settings, "site_url")
  config.siteName = jstr(settings, "site_name")

proc switchProvider*(config: var AgentConfig, provider: string) =
  let p = provider.toLowerAscii
  if p notin WiredProviders: raise newException(ValueError, "unsupported provider: " & p)
  if config.model.len > 0: config.lastModels[config.provider] = config.model
  config.fillProvider(p)
  config.model = config.lastModels.getOrDefault(p, defaultProviderModel(p))
  config.defaultModel = config.model

proc apiKey*(config: AgentConfig): string
proc apiKeyDescription*(config: AgentConfig): string

proc doctorReport*(config: AgentConfig): string =
  result = "Provider: " & config.provider & "\nModel: " & config.model
  var endpoint = parseUri(config.endpoint)
  endpoint.username = ""
  endpoint.password = ""
  endpoint.query = ""
  endpoint.anchor = ""
  result.add "\nEndpoint: " & $endpoint
  result.add "\nConfig sources (later overrides earlier):"
  for path in config.sourcePaths:
    result.add "\n  " & path & (if fileExists(path): " (exists)" else: " (absent)")
  result.add "\nConfig write target: " & config.writePath
  result.add "\nAuth file: " & config.authPath &
    (if fileExists(config.authPath): " (exists)" else: " (absent)")
  for p in WiredProviders:
    if p == "codex":
      result.add "\n" & p & ": Codex App Server"
      continue
    var selected = config
    selected.fillProvider(p)
    result.add "\n" & p & ": " & selected.apiKeyDescription & " " &
      (if selected.apiKey.len > 0: "set" else: "missing")
  result.add "\nUse /doctor test for a small API request to the selected provider."

proc expandConfigPath(value, fallback: string): string =
  if value.len == 0:
    return fallback
  if value == "~":
    return getHomeDir()
  if value.startsWith("~/"):
    return (getHomeDir() / value[2 .. ^1]).normalizedPath
  if value.isAbsolute:
    return value.normalizedPath
  (getCurrentDir() / value).normalizedPath

proc applyDoc(config: var AgentConfig, doc: JsonNode) =
  config.providers = jobj(doc, "providers")
  for p in WiredProviders:
    let last = jstr(jobj(config.providers, p), "last_model")
    if last.len > 0: config.lastModels[p] = last
  config.provider = jstr(doc, "default_provider", "openrouter")
  if config.provider.len == 0:
    config.provider = "openrouter"
  config.model = jstr(doc, "default_model")
  if config.model.len == 0:
    config.model = config.lastModels.getOrDefault(config.provider,
      defaultProviderModel(config.provider))
  config.defaultModel = config.model
  config.theme = jstr(doc, "theme", "auto")
  if config.theme.len == 0:
    config.theme = "auto"
  config.fillProvider(config.provider)
  let agent = jobj(doc, "agent")
  config.maxTokens = jint(agent, "max_tokens", 4096)
  config.contextWindow = jint(agent, "context_window", 0)
  config.compactionEnabled = jbool(agent, "compaction_enabled", true)
  config.reserveTokens = jint(agent, "reserve_tokens", defaultReserveTokens)
  config.keepRecentTokens = jint(agent, "keep_recent_tokens", defaultKeepRecentTokens)
  var thinking = jstr(agent, "thinking")
  let envThinking = getEnv("NIMLET_THINKING")
  if envThinking.len > 0:
    thinking = envThinking
  config.thinking = if thinking.len == 0: "" else: normalizeThinking(thinking)
  config.steeringMode = normalizeQueueMode(jstr(agent, "steering_mode",
    DefaultQueueMode))
  config.followUpMode = normalizeQueueMode(jstr(agent, "follow_up_mode",
    DefaultQueueMode))
  config.webSearch = jbool(agent, "web_search", false)
  config.requestTimeout = jint(agent, "request_timeout", 300)
  config.sessionDir = expandConfigPath(jstr(agent, "session_dir"),
    nimletConfigDir() / "sessions")
  config.maxToolOutputBytes = jint(jobj(jobj(doc, "tools"), "bash"),
    "max_output_bytes", 100_000)
  config.keybindings = jobj(doc, "keybindings")

proc ensureAgentObj(doc: var JsonNode) =
  if "agent" notin doc or doc["agent"].kind != JObject:
    doc["agent"] = newJObject()

proc persistModel*(config: AgentConfig) =
  ## Patch model, provider, thinking, web_search, and theme on the write target.
  if config.writePath.len == 0: return
  var doc = loadJsonFile(config.writePath)
  if config.provider.len > 0:
    doc["default_provider"] = %config.provider
  if config.model.len > 0:
    doc["default_model"] = %config.model
  if "providers" notin doc or doc["providers"].kind != JObject:
    doc["providers"] = newJObject()
  var remembered = config.lastModels
  remembered[config.provider] = config.model
  for p, model in remembered:
    if p.len == 0 or model.len == 0: continue
    if p notin doc["providers"] or doc["providers"][p].kind != JObject:
      doc["providers"][p] = newJObject()
    doc["providers"][p]["last_model"] = %model
  if config.theme.len > 0:
    doc["theme"] = %config.theme
  if config.thinking.len > 0:
    ensureAgentObj(doc)
    doc["agent"]["thinking"] = %config.thinking
  elif "agent" in doc and doc["agent"].kind == JObject and "thinking" in doc["agent"]:
    delete(doc["agent"], "thinking")
  if config.webSearch:
    ensureAgentObj(doc)
    doc["agent"]["web_search"] = %true
  elif "agent" in doc and doc["agent"].kind == JObject and "web_search" in doc["agent"]:
    delete(doc["agent"], "web_search")
  let dir = config.writePath.parentDir
  if dir.len > 0: createDir(dir)
  writeFile(config.writePath, pretty(doc) & "\n")

proc persistQueueModes*(config: AgentConfig) =
  if config.writePath.len == 0: return
  var doc = loadJsonFile(config.writePath)
  ensureAgentObj(doc)
  let steering = if config.steeringMode.len == 0: DefaultQueueMode
                 else: normalizeQueueMode(config.steeringMode)
  let followUp = if config.followUpMode.len == 0: DefaultQueueMode
                 else: normalizeQueueMode(config.followUpMode)
  doc["agent"]["steering_mode"] = %steering
  doc["agent"]["follow_up_mode"] = %followUp
  let dir = config.writePath.parentDir
  if dir.len > 0: createDir(dir)
  writeFile(config.writePath, pretty(doc) & "\n")

proc loadConfig*(workspace = getCurrentDir(), configPath = "",
                 globalPath = "", authPath = ""): AgentConfig =
  result.workspace = expandFilename(workspace)
  result.authPath = if authPath.len > 0: authPath
                    else: nimletConfigDir() / "auth.json"
  result.auth = loadJsonFile(result.authPath)
  if configPath.len > 0:
    result.sourcePaths = @[configPath]
    result.writePath = configPath
    result.applyDoc(loadJsonFile(configPath))
    return
  let globalFile = if globalPath.len > 0: globalPath
                   else: nimletConfigDir() / "config.json"
  let projectDir = result.workspace / ".nimlet"
  let projectFile = projectDir / "config.json"
  result.sourcePaths = @[globalFile, projectFile]
  let useProject = projectResourcesTrusted(result.workspace)
  result.writePath = if useProject and dirExists(projectDir): projectFile else: globalFile
  let globalDoc = loadJsonFile(globalFile)
  let projectDoc = if useProject:
    loadJsonFile(projectFile)
  else:
    newJObject()
  result.applyDoc(overlay(globalDoc, projectDoc))

proc apiKey*(config: AgentConfig): string =
  if config.apiKeyOverride.len > 0 and config.apiKeyOverrideProvider == config.provider:
    return config.apiKeyOverride
  let auth = config.authEntry(config.provider)
  let kind = config.authType(config.provider)
  if kind.len > 0:
    return if kind == "api_key": jstr(auth, "key") else: ""
  let resolved = apiKeyEnv(config.provider)
  if resolved.len == 0: return ""
  getEnv(resolved)

proc apiKeyDescription*(config: AgentConfig): string =
  if config.provider.toLowerAscii == "codex":
    return "Codex App Server"
  if config.apiKeyOverride.len > 0 and config.apiKeyOverrideProvider == config.provider:
    return "command line"
  let kind = config.authType(config.provider)
  if kind.len > 0:
    return "auth " & config.authPath & " (" & kind & ")"
  let resolved = apiKeyEnv(config.provider)
  "env " & (if resolved.len > 0: resolved else: defaultApiKeyEnv(config.provider))
