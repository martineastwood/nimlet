## models.dev catalog: context windows and related model metadata.
##
## Reads https://models.dev/api.json from a disk cache without network I/O.
## An explicit refresh can update the cache; lookups fail open offline.
## Lookup order is handled by config.effectiveContextWindow:
## config override → models.dev → name heuristic.

import std/[asyncdispatch, httpclient, json, os, streams, strutils, tables, times]
import nimgent

type
  ModelCost* = object
    found*: bool
    input*: float    ## USD per 1M tokens
    output*: float
    cacheRead*: float
    cacheWrite*: float

  CatalogIndexEntry = object
    provider, id, idLower: string
    context: int
    reasoning, toggle, budgetTokens, acceptsImages: bool
    efforts: seq[string]
    npm: string
    cost: ModelCost

  CatalogSnapshot = object
    valid: bool
    entries: seq[CatalogIndexEntry]
    exact, lower: Table[string, int]

const
  modelsDevUrl* = "https://models.dev/api.json"
  defaultTtlSeconds = 24 * 60 * 60
  catalogStaleSeconds* = 24 * 60 * 60

var
  gCatalogPath = ""
  gLoadedAt = 0.0
  gForcePath = ""  ## tests: pin cache file / skip network when pre-seeded
  gCatalogLoaded = false
  gCatalogIndex: seq[CatalogIndexEntry]
  gCatalogExact: Table[string, int]
  gCatalogLower: Table[string, int]

proc cachePath(): string =
  if gForcePath.len > 0: return gForcePath
  if gCatalogPath.len > 0: return gCatalogPath
  result = getHomeDir() / ".nimlet" / "models-dev.json"
  gCatalogPath = result

proc setModelsDevCachePath*(path: string) =
  ## Test/helper hook: use a fixed cache file (no network if file exists).
  gForcePath = path
  gCatalogLoaded = false
  gLoadedAt = 0
  gCatalogIndex.setLen(0)
  gCatalogExact = initTable[string, int]()
  gCatalogLower = initTable[string, int]()

proc catalogKey(provider, id: string): string = provider & "\x1f" & id

proc parserError(parser: JsonParser) {.noreturn.} =
  raise newException(ValueError, parser.errorMsg())

proc skipValue(parser: var JsonParser) =
  case parser.kind
  of jsonObjectStart, jsonArrayStart:
    var depth = 1
    while depth > 0:
      parser.next()
      case parser.kind
      of jsonObjectStart, jsonArrayStart: inc depth
      of jsonObjectEnd, jsonArrayEnd: dec depth
      of jsonError: parser.parserError()
      else: discard
  of jsonError:
    parser.parserError()
  else: discard

proc parserFloat(parser: JsonParser): float =
  case parser.kind
  of jsonInt: parser.getInt.float
  of jsonFloat: parser.getFloat
  of jsonString:
    try: parseFloat(parser.str)
    except ValueError: 0.0
  else: 0.0

proc parseLimit(parser: var JsonParser, entry: var CatalogIndexEntry) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    if key == "context" and parser.kind == jsonInt:
      entry.context = parser.getInt.int
    else:
      parser.skipValue()
    parser.next()

proc parseCost(parser: var JsonParser, entry: var CatalogIndexEntry) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    let value = parser.parserFloat()
    case key
    of "input": entry.cost.input = value
    of "output": entry.cost.output = value
    of "cache_read": entry.cost.cacheRead = value
    of "cache_write": entry.cost.cacheWrite = value
    else: discard
    if parser.kind in {jsonObjectStart, jsonArrayStart}:
      parser.skipValue()
    parser.next()
  entry.cost.found = entry.cost.input > 0 or entry.cost.output > 0

proc parseStringArray(parser: var JsonParser, values: var seq[string]) =
  if parser.kind != jsonArrayStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonArrayEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind == jsonString: values.add parser.str
    else: parser.skipValue()
    parser.next()

proc parseReasoningOptions(parser: var JsonParser, entry: var CatalogIndexEntry) =
  if parser.kind != jsonArrayStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonArrayEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonObjectStart:
      parser.skipValue()
      parser.next()
      continue
    var optionType = ""
    var values: seq[string]
    parser.next()
    while parser.kind != jsonObjectEnd:
      if parser.kind == jsonError: parser.parserError()
      if parser.kind != jsonString: parser.parserError()
      let key = parser.str
      parser.next()
      if key == "type" and parser.kind == jsonString:
        optionType = parser.str
      elif key == "values":
        parser.parseStringArray(values)
      else:
        parser.skipValue()
      parser.next()
    case optionType
    of "toggle": entry.toggle = true
    of "budget_tokens": entry.budgetTokens = true
    of "effort":
      for value in values:
        let effort = value.strip.toLowerAscii
        if effort.len > 0 and effort notin entry.efforts:
          entry.efforts.add effort
    else: discard
    parser.next()

proc parseProvider(parser: var JsonParser, entry: var CatalogIndexEntry) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    if key == "npm" and parser.kind == jsonString: entry.npm = parser.str
    else: parser.skipValue()
    parser.next()

proc parseModalities(parser: var JsonParser, entry: var CatalogIndexEntry) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    if key == "input":
      var inputs: seq[string]
      parser.parseStringArray(inputs)
      entry.acceptsImages = "image" in inputs
    else:
      parser.skipValue()
    parser.next()

proc parseModel(parser: var JsonParser, provider, id: string): CatalogIndexEntry =
  result = CatalogIndexEntry(provider: provider, id: id, idLower: id.toLowerAscii)
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    case key
    of "limit": parser.parseLimit(result)
    of "reasoning":
      if parser.kind == jsonTrue:
        result.reasoning = true
      elif parser.kind in {jsonObjectStart, jsonArrayStart}:
        parser.skipValue()
    of "reasoning_options": parser.parseReasoningOptions(result)
    of "provider": parser.parseProvider(result)
    of "modalities": parser.parseModalities(result)
    of "cost": parser.parseCost(result)
    else: parser.skipValue()
    parser.next()
  if result.toggle or result.budgetTokens or result.efforts.len > 0:
    result.reasoning = true

proc addCatalogEntry(snapshot: var CatalogSnapshot, entry: CatalogIndexEntry) =
  let index = snapshot.entries.len
  snapshot.entries.add entry
  snapshot.exact[catalogKey(entry.provider, entry.id)] = index
  snapshot.lower[catalogKey(entry.provider.toLowerAscii, entry.idLower)] = index

proc parseModels(parser: var JsonParser, provider: string,
                 snapshot: var CatalogSnapshot) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let id = parser.str
    parser.next()
    if parser.kind == jsonObjectStart:
      snapshot.addCatalogEntry(parser.parseModel(provider, id))
    else:
      parser.skipValue()
    parser.next()

proc parseProviderCatalog(parser: var JsonParser, provider: string,
                          snapshot: var CatalogSnapshot) =
  if parser.kind != jsonObjectStart:
    parser.skipValue()
    return
  parser.next()
  while parser.kind != jsonObjectEnd:
    if parser.kind == jsonError: parser.parserError()
    if parser.kind != jsonString: parser.parserError()
    let key = parser.str
    parser.next()
    if key == "models": parser.parseModels(provider, snapshot)
    else: parser.skipValue()
    parser.next()

proc parseCatalogStream(input: Stream, filename: string): CatalogSnapshot =
  result.exact = initTable[string, int]()
  result.lower = initTable[string, int]()
  var parser: JsonParser
  parser.open(input, filename)
  try:
    parser.next()
    if parser.kind == jsonObjectStart:
      parser.next()
      while parser.kind != jsonObjectEnd:
        if parser.kind == jsonError: parser.parserError()
        if parser.kind != jsonString: parser.parserError()
        let provider = parser.str
        parser.next()
        parser.parseProviderCatalog(provider, result)
        parser.next()
    else:
      parser.skipValue()
    parser.next()
    if parser.kind != jsonEof:
      parser.parserError()
    result.valid = true
  finally:
    parser.close()

proc parseCatalog(raw, filename: string): CatalogSnapshot =
  parseCatalogStream(newStringStream(raw), filename)

proc parseCatalogFile(path: string): CatalogSnapshot =
  result.exact = initTable[string, int]()
  result.lower = initTable[string, int]()
  if not fileExists(path): return
  let input = newFileStream(path, fmRead)
  if input.isNil: return
  parseCatalogStream(input, path)

proc installCatalog(snapshot: CatalogSnapshot) =
  gCatalogIndex = snapshot.entries
  gCatalogExact = snapshot.exact
  gCatalogLower = snapshot.lower
  gCatalogLoaded = true

proc ensureCatalog() =
  ## Load and compact the catalog without retaining its parsed JSON tree.
  if gCatalogLoaded and gLoadedAt > 0 and
      epochTime() - gLoadedAt < defaultTtlSeconds.float:
    return

  let path = cachePath()
  var snapshot: CatalogSnapshot
  try:
    snapshot = parseCatalogFile(path)
  except CatchableError:
    snapshot.valid = false
  installCatalog(snapshot)
  gLoadedAt = epochTime()

proc findCatalogIndex(provider, model: string): int =
  ensureCatalog()
  let exact = gCatalogExact.getOrDefault(catalogKey(provider, model), -1)
  if exact >= 0: return exact
  if "/" in model:
    let bare = model.rsplit('/', 1)[^1]
    let bareExact = gCatalogExact.getOrDefault(catalogKey(provider, bare), -1)
    if bareExact >= 0: return bareExact
  gCatalogLower.getOrDefault(catalogKey(provider.toLowerAscii, model.toLowerAscii), -1)

proc findCatalogIndexAnywhere(model: string): int =
  ensureCatalog()
  let want = model.toLowerAscii
  let bare = if "/" in model: model.rsplit('/', 1)[^1].toLowerAscii else: want
  for i, entry in gCatalogIndex:
    if entry.idLower == want or entry.idLower == bare or
        entry.idLower.endsWith("/" & bare):
      return i
  -1

proc catalogName*(provider: string): string =
  ## Logical provider name → models.dev catalog key, when the two differ.
  ## OpenCode Zen and its Go subscription share no model ids and both have
  ## their own catalog entry; nimlet keys Zen as `opencodezen`.
  case provider.toLowerAscii
  of "opencode": "opencode-go"
  of "opencodezen": "opencode"
  else: provider

proc resolveModelIndex(provider, model: string): int =
  ## Provider catalog, then OpenRouter, then any name match. Nil if unknown.
  if model.len == 0: return -1
  let p = provider.toLowerAscii.strip
  result = findCatalogIndex(catalogName(p), model)
  if result >= 0: return
  if p != "openrouter":
    result = findCatalogIndex("openrouter", model)
    if result >= 0: return
  result = findCatalogIndexAnywhere(model)

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
  let index = findCatalogIndex(catalogName(provider), model)
  if index < 0: return
  let entry = gCatalogIndex[index]
  result.known = true
  result.reasoning = entry.reasoning
  result.toggle = entry.toggle
  result.budgetTokens = entry.budgetTokens
  result.efforts = entry.efforts

proc lookupContextWindow*(provider, model: string): int =
  ## Context tokens for `provider`/`model`, or 0 if unknown / offline.
  let index = resolveModelIndex(provider, model)
  if index >= 0: return gCatalogIndex[index].context

proc modelApiPackage*(provider, model: string): string =
  ## `provider.npm` for this model: which wire the gateway serves it on, as
  ## `@ai-sdk/openai` (Responses), `@ai-sdk/openai-compatible` (chat), or
  ## `@ai-sdk/anthropic` (messages). "" when the catalog has no entry or opinion.
  let index = findCatalogIndex(catalogName(provider), model)
  if index >= 0: return gCatalogIndex[index].npm

proc lookupAcceptsImages*(provider, model: string): bool =
  ## True when the catalog lists image input, or the model is unknown (fail-open).
  let index = resolveModelIndex(provider, model)
  if index < 0: return model.len > 0
  gCatalogIndex[index].acceptsImages

proc lookupModelCost*(provider, model: string): ModelCost =
  if model.len == 0: return
  let index = resolveModelIndex(provider, model)
  if index >= 0: return gCatalogIndex[index].cost

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
    let snapshot = parseCatalog(body, modelsDevUrl)
    if not snapshot.valid:
      raise newException(ValueError, "invalid models.dev catalog")
    createDir(parentDir(path))
    let tmp = path & ".tmp"
    try:
      writeFile(tmp, body)
      moveFile(tmp, path)
    except CatchableError:
      if fileExists(tmp): removeFile(tmp)
      raise
    installCatalog(snapshot)
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
  ensureCatalog()
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
