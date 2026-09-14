## models.dev catalog: context windows and related model metadata.
##
## Reads https://models.dev/api.json from a disk cache without network I/O.
## An explicit refresh can update the cache; lookups fail open offline.
## Lookup order is handled by config.effectiveContextWindow:
## config override → models.dev → name heuristic.

import std/[asyncdispatch, httpclient, json, os, strutils, times]
import nimgent

type CatalogIndexEntry = object
  provider, id, idLower: string
  context: int

const
  modelsDevUrl* = "https://models.dev/api.json"
  defaultTtlSeconds = 24 * 60 * 60
  catalogStaleSeconds* = 24 * 60 * 60

var
  gCatalog: JsonNode
  gCatalogPath = ""
  gLoadedAt = 0.0
  gForcePath = ""  ## tests: pin cache file / skip network when pre-seeded
  gCatalogIndex: seq[CatalogIndexEntry]
  gCatalogIndexLoadedAt = -1.0

proc cachePath(): string =
  if gForcePath.len > 0: return gForcePath
  if gCatalogPath.len > 0: return gCatalogPath
  result = getHomeDir() / ".nimlet" / "models-dev.json"
  gCatalogPath = result

proc setModelsDevCachePath*(path: string) =
  ## Test/helper hook: use a fixed cache file (no network if file exists).
  gForcePath = path
  gCatalog = nil
  gLoadedAt = 0
  gCatalogIndexLoadedAt = -1

proc contextFromModelNode(node: JsonNode): int =
  if node.isNil or node.kind != JObject: return 0
  let limit = node.getOrDefault("limit")
  if not limit.isNil and limit.kind == JObject:
    result = limit.getOrDefault("context").getInt

proc findModelNode(catalog: JsonNode, provider, model: string): JsonNode =
  if catalog.isNil or catalog.kind != JObject: return nil
  let prov = catalog.getOrDefault(provider)
  if prov.isNil or prov.kind != JObject: return nil
  let models = prov.getOrDefault("models")
  if models.isNil or models.kind != JObject: return nil
  result = models.getOrDefault(model)
  if not result.isNil and result.kind == JObject: return
  if "/" in model:
    result = models.getOrDefault(model.rsplit('/', 1)[^1])
    if not result.isNil and result.kind == JObject: return
  let want = model.toLowerAscii
  for key, node in models:
    if key.toLowerAscii == want and not node.isNil and node.kind == JObject:
      return node
  result = nil

proc modelKeyMatch(key, want, bare: string): bool =
  let k = key.toLowerAscii
  k == want or k == bare or k.endsWith("/" & bare)

proc findModelNodeAnywhere(catalog: JsonNode, model: string): JsonNode =
  if catalog.isNil or catalog.kind != JObject: return nil
  let want = model.toLowerAscii
  let bare = if "/" in model: model.rsplit('/', 1)[^1].toLowerAscii else: want
  for _, prov in catalog:
    if prov.isNil or prov.kind != JObject: continue
    let models = prov.getOrDefault("models")
    if models.isNil or models.kind != JObject: continue
    for key, node in models:
      if modelKeyMatch(key, want, bare) and not node.isNil and node.kind == JObject:
        return node

proc loadCatalogFromDisk(path: string): JsonNode =
  if not fileExists(path): return nil
  try:
    result = parseJson(readFile(path))
  except CatchableError:
    result = nil

proc ensureCatalog(): JsonNode =
  ## Return parsed catalog from memory or disk without doing network I/O.
  if not gCatalog.isNil and gLoadedAt > 0 and
      epochTime() - gLoadedAt < defaultTtlSeconds.float:
    return gCatalog

  let path = cachePath()
  let disk = loadCatalogFromDisk(path)
  if not disk.isNil:
    gCatalog = disk
    gLoadedAt = epochTime()
    return gCatalog
  gCatalog = newJObject()
  gLoadedAt = epochTime()
  gCatalog

proc catalogName*(provider: string): string =
  ## Logical provider name → models.dev catalog key, when the two differ.
  ## OpenCode Zen and its Go subscription share no model ids and both have
  ## their own catalog entry; nimlet keys Zen as `opencodezen`.
  case provider.toLowerAscii
  of "opencode": "opencode-go"
  of "opencodezen": "opencode"
  else: provider

proc resolveModelNode(provider, model: string): JsonNode =
  ## Provider catalog, then OpenRouter, then any name match. Nil if unknown.
  if model.len == 0: return nil
  let catalog = ensureCatalog()
  let p = provider.toLowerAscii.strip
  result = findModelNode(catalog, catalogName(p), model)
  if not result.isNil: return
  if p != "openrouter":
    result = findModelNode(catalog, "openrouter", model)
    if not result.isNil: return
  result = findModelNodeAnywhere(catalog, model)

type
  ReasoningCaps* = object
    known*: bool
    reasoning*: bool
    toggle*: bool
    budgetTokens*: bool
    efforts*: seq[string]

proc lookupReasoningCaps*(provider, model: string): ReasoningCaps =
  ## Caps for this provider's catalog entry only. Miss → known=false (fail-open).
  if provider.len == 0 or model.len == 0: return
  let node = findModelNode(ensureCatalog(), catalogName(provider), model)
  if node.isNil or node.kind != JObject: return
  result.known = true
  result.reasoning = node.getOrDefault("reasoning").getBool
  let opts = node.getOrDefault("reasoning_options")
  if opts.isNil or opts.kind != JArray: return
  for item in opts:
    if item.kind != JObject: continue
    case item.getOrDefault("type").getStr
    of "toggle":
      result.toggle = true
    of "budget_tokens":
      result.budgetTokens = true
    of "effort":
      let vals = item.getOrDefault("values")
      if vals.kind != JArray: continue
      for v in vals:
        let s = v.getStr.strip.toLowerAscii
        if s.len == 0: continue
        var seen = false
        for e in result.efforts:
          if e == s: seen = true
        if not seen: result.efforts.add s
  if result.toggle or result.budgetTokens or result.efforts.len > 0:
    result.reasoning = true

proc lookupContextWindow*(provider, model: string): int =
  ## Context tokens for `provider`/`model`, or 0 if unknown / offline.
  contextFromModelNode(resolveModelNode(provider, model))

proc modelApiPackage*(provider, model: string): string =
  ## `provider.npm` for this model: which wire the gateway serves it on, as
  ## `@ai-sdk/openai` (Responses), `@ai-sdk/openai-compatible` (chat), or
  ## `@ai-sdk/anthropic` (messages). "" when the catalog has no entry or opinion.
  let node = findModelNode(ensureCatalog(), catalogName(provider), model)
  if node.isNil: return ""
  node.getOrDefault("provider").getOrDefault("npm").getStr

proc nodeAcceptsImages(node: JsonNode): bool =
  if node.isNil or node.kind != JObject: return false
  let inputs = node.getOrDefault("modalities").getOrDefault("input")
  if inputs.isNil or inputs.kind != JArray: return false
  for item in inputs:
    if item.getStr == "image": return true

proc lookupAcceptsImages*(provider, model: string): bool =
  ## True when the catalog lists image input, or the model is unknown (fail-open).
  let node = resolveModelNode(provider, model)
  if node.isNil: return model.len > 0
  nodeAcceptsImages(node)

type
  ModelCost* = object
    found*: bool
    input*: float    ## USD per 1M tokens
    output*: float
    cacheRead*: float
    cacheWrite*: float

proc jfloat(n: JsonNode, key: string, fallback = 0.0): float =
  if n.isNil or n.kind != JObject or key notin n: return fallback
  let v = n[key]
  case v.kind
  of JFloat: v.getFloat
  of JInt: v.getInt.float
  of JString:
    try: parseFloat(v.getStr)
    except ValueError: fallback
  else: fallback

proc costFromNode(node: JsonNode): ModelCost =
  if node.isNil or node.kind != JObject: return
  let cost = node.getOrDefault("cost")
  if cost.isNil or cost.kind != JObject: return
  result.input = jfloat(cost, "input")
  result.output = jfloat(cost, "output")
  result.cacheRead = jfloat(cost, "cache_read")
  result.cacheWrite = jfloat(cost, "cache_write")
  result.found = result.input > 0 or result.output > 0

proc lookupModelCost*(provider, model: string): ModelCost =
  if model.len == 0: return
  result = costFromNode(resolveModelNode(provider, model))

proc formatUsd*(amount: float): string =
  if amount <= 0: return "$0"
  if amount < 0.01: return "$" & amount.formatFloat(ffDecimal, 4)
  "$" & amount.formatFloat(ffDecimal, 2)

proc estimateUsageCost*(provider, model: string, usage: Usage): float =
  ## USD for this usage row, or 0 if the catalog has no price.
  let cost = lookupModelCost(provider, model)
  if not cost.found: return 0
  var uncached = usage.inputTokens.float
  var cacheR = usage.cacheReadTokens.float
  var cacheW = usage.cacheWriteTokens.float
  if usage.cacheReported and cacheR + cacheW > 0 and
      usage.inputTokens.float + 0.5 < cacheR + cacheW:
    # Anthropic-style: input is uncached; cache tokens are extra.
    discard
  else:
    # OpenRouter-style: prompt_tokens includes cached reads.
    uncached = max(0.0, usage.inputTokens.float - cacheR)
  let readPrice = if cost.cacheRead > 0: cost.cacheRead else: cost.input
  let writePrice = if cost.cacheWrite > 0: cost.cacheWrite else: cost.input
  (uncached * cost.input + cacheR * readPrice + cacheW * writePrice +
    usage.outputTokens.float * cost.output) / 1_000_000.0

proc formatUsageCost*(provider, model: string, usage: Usage): string =
  if usage.inputTokens == 0 and usage.outputTokens == 0: return
  if not lookupModelCost(provider, model).found: return
  formatUsd(estimateUsageCost(provider, model, usage))

proc refreshModelsDevCacheAsync*(): Future[bool] {.async.} =
  ## Explicit best-effort refresh; false on any failure and the old cache stays.
  let path = cachePath()
  try:
    let client = newAsyncHttpClient()
    client.timeout = 20_000
    defer: client.close()
    let body = await client.getContent(modelsDevUrl)
    let parsed = parseJson(body)
    createDir(parentDir(path))
    let tmp = path & ".tmp"
    try:
      writeFile(tmp, body)
      moveFile(tmp, path)
    except CatchableError:
      if fileExists(tmp): removeFile(tmp)
      raise
    gCatalog = parsed
    gLoadedAt = epochTime()
    true
  except CatchableError:
    false

proc modelsDevCacheStale*(maxAgeSeconds = catalogStaleSeconds): bool =
  let path = cachePath()
  if not fileExists(path): return true
  epochTime() - getLastModificationTime(path).toUnix.float >= maxAgeSeconds.float

proc refreshStaleCatalogAsync*(): Future[bool] {.async.} =
  ## Refresh only when the catalog is missing or past its TTL. Lookups keep
  ## working offline until it lands, and pickers retain model ids they already
  ## know.
  if not modelsDevCacheStale(): return false
  return await refreshModelsDevCacheAsync()

type
  CatalogModel* = object
    provider*: string
    id*: string
    context*: int

proc formatContextK*(n: int): string =
  if n >= 1000: $(n div 1000) & "k"
  else: $n

proc orderedProviders(providers: openArray[string], prefer: string): seq[string] =
  let pref = prefer.toLowerAscii
  var names: seq[string]
  if pref.len > 0: names.add pref
  names.add "openrouter"
  for p in providers:
    names.add p.toLowerAscii
  for n in names:
    if n.len == 0: continue
    var already = false
    for x in result:
      if x.toLowerAscii == n:
        already = true
        break
    if already: continue
    for x in providers:
      if x.toLowerAscii == n:
        result.add x
        break

proc catalogIndex(): seq[CatalogIndexEntry] =
  let catalog = ensureCatalog()
  if gCatalogIndexLoadedAt == gLoadedAt:
    return gCatalogIndex
  gCatalogIndex.setLen(0)
  for provider, node in catalog:
    if node.isNil or node.kind != JObject: continue
    let models = node.getOrDefault("models")
    if models.isNil or models.kind != JObject: continue
    for id, model in models:
      gCatalogIndex.add CatalogIndexEntry(provider: provider,
        id: id, idLower: id.toLowerAscii,
        context: contextFromModelNode(model))
  gCatalogIndexLoadedAt = gLoadedAt
  gCatalogIndex

proc findCatalogModel*(id: string, providers: openArray[string],
                       prefer = ""): tuple[found: bool, model: CatalogModel] =
  ## Exact id match. Prefer `prefer`, then OpenRouter, then the rest.
  if id.len == 0: return
  let want = id.toLowerAscii
  for p in orderedProviders(providers, prefer):
    let logical = p.toLowerAscii
    let provider = catalogName(logical)
    for entry in catalogIndex():
      if entry.provider == provider and entry.idLower == want:
        return (true, CatalogModel(provider: logical, id: entry.id,
          context: entry.context))

proc searchCatalogModels*(providers: openArray[string], query: string,
                          cap: int, prefer = "",
                          skip: openArray[string] = []): seq[CatalogModel] =
  ## Substring match on id, `prefer` provider first. Cap at `cap`.
  if cap <= 0: return
  let q = query.toLowerAscii
  var seen: seq[string]
  for s in skip:
    seen.add s.toLowerAscii
  var acc: seq[CatalogModel]
  proc take(p: string) =
    if acc.len >= cap: return
    let logical = p.toLowerAscii
    let provider = catalogName(logical)
    for entry in catalogIndex():
      if acc.len >= cap: return
      if entry.provider != provider or q notin entry.idLower: continue
      if entry.idLower in seen: continue
      seen.add entry.idLower
      acc.add CatalogModel(provider: logical, id: entry.id,
        context: entry.context)
  for p in orderedProviders(providers, prefer):
    take(p)
  acc
