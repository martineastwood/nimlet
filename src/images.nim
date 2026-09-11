## Image sniffing, token estimates, session hydrate, and clip ingest.
##
## Workspace stays the sandbox. This module owns the image bytes.

import std/[base64, os, strutils, times]
import workspace
import nimgent

const
  MaxImageBytes* = 5 * 1024 * 1024
  imageTokenFallback* = 2000
  imageTilePx = 1568
  imageTokensPerTile = 1600

proc sniffImageMime*(raw: string): string =
  ## Magic-byte MIME for the image types Anthropic/OpenAI accept, or empty.
  if raw.len >= 8 and raw.startsWith("\x89PNG\r\n\x1a\n"):
    return "image/png"
  if raw.len >= 3 and raw[0] == '\xFF' and raw[1] == '\xD8' and raw[2] == '\xFF':
    return "image/jpeg"
  if raw.len >= 6 and raw.startsWith("GIF8") and raw[5] in {'a', 'A'}:
    return "image/gif"
  if raw.len >= 12 and raw.startsWith("RIFF") and raw[8 .. 11] == "WEBP":
    return "image/webp"

proc classifyImage*(raw: string): tuple[ok: bool, mime, err: string] =
  ## Sniff + size check. Does not base64-encode.
  result.mime = sniffImageMime(raw)
  if result.mime.len == 0:
    return
  if raw.len > MaxImageBytes:
    result.err = "image too large (" & $raw.len & " bytes; max " &
      $MaxImageBytes & ")"
    return
  result.ok = true

proc imagePayload*(raw: string): tuple[ok: bool, mime, data, err: string] =
  ## Base64 payload for a sniffed image, or an error if it is an oversize image.
  ## Non-images return ok=false with empty mime and err.
  let c = classifyImage(raw)
  result.ok = c.ok
  result.mime = c.mime
  result.err = c.err
  if c.ok:
    result.data = encode(raw)

proc readU32be(s: string, i: int): int =
  if i + 4 > s.len: return 0
  (ord(s[i]).int shl 24) or (ord(s[i + 1]).int shl 16) or
    (ord(s[i + 2]).int shl 8) or ord(s[i + 3]).int

proc imageDimensions*(raw: string): tuple[w, h: int] =
  ## Pixel size from a magic-byte header, or 0,0 if unknown.
  case sniffImageMime(raw)
  of "image/png":
    if raw.len >= 24:
      result.w = readU32be(raw, 16)
      result.h = readU32be(raw, 20)
  of "image/gif":
    if raw.len >= 10:
      result.w = ord(raw[6]).int or (ord(raw[7]).int shl 8)
      result.h = ord(raw[8]).int or (ord(raw[9]).int shl 8)
  of "image/jpeg":
    var i = 2
    while i + 8 < raw.len:
      if raw[i] != '\xFF':
        inc i
        continue
      let marker = uint8(raw[i + 1])
      if marker in {0xC0'u8, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                    0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
        result.h = (ord(raw[i + 5]).int shl 8) or ord(raw[i + 6]).int
        result.w = (ord(raw[i + 7]).int shl 8) or ord(raw[i + 8]).int
        return
      if marker == 0xD8'u8 or marker == 0xD9'u8 or
          (marker >= 0xD0'u8 and marker <= 0xD7'u8):
        i += 2
        continue
      if i + 3 >= raw.len: return
      let len = (ord(raw[i + 2]).int shl 8) or (ord(raw[i + 3]).int)
      if len < 2: return
      i += 2 + len
  of "image/webp":
    if raw.len >= 30 and raw[12 .. 15] == "VP8X":
      result.w = 1 + (ord(raw[24]).int or (ord(raw[25]).int shl 8) or
        (ord(raw[26]).int shl 16))
      result.h = 1 + (ord(raw[27]).int or (ord(raw[28]).int shl 8) or
        (ord(raw[29]).int shl 16))
    elif raw.len >= 30 and raw[12 .. 15] == "VP8 ":
      result.w = (ord(raw[26]).int or (ord(raw[27]).int shl 8)) and 0x3FFF
      result.h = (ord(raw[28]).int or (ord(raw[29]).int shl 8)) and 0x3FFF
  else:
    discard

proc imageDimensionsFile*(path: string): tuple[w, h: int] =
  if path.len == 0 or not fileExists(path): return
  try:
    let cap = min(int(getFileSize(path)), 32_768)
    if cap <= 0: return
    let f = open(path)
    var buf = newString(cap)
    let n = f.readBuffer(addr buf[0], cap)
    f.close()
    buf.setLen(n)
    result = imageDimensions(buf)
  except CatchableError:
    discard

proc imageTokenEstimate*(img: ImageContent, root = ""): int =
  ## Anthropic-style tile count. Path headers beat a flat 2000; byte/4 would
  ## compact after one screenshot.
  var path = img.path
  if path.len > 0 and root.len > 0 and not path.isAbsolute:
    path = root / path
  var w, h = 0
  if path.len > 0:
    (w, h) = imageDimensionsFile(path)
  if w <= 0 or h <= 0:
    return imageTokenFallback
  let tw = (w + imageTilePx - 1) div imageTilePx
  let th = (h + imageTilePx - 1) div imageTilePx
  max(imageTokensPerTile, tw * th * imageTokensPerTile)

proc hydrateImage*(ws: Workspace, img: ImageContent): ImageContent =
  ## Fill base64 from `path` when the session stored a file reference.
  result = img
  if result.data.len > 0 or result.path.len == 0:
    return
  try:
    let resolved = ws.resolve(result.path)
    if not fileExists(resolved): return
    let payload = imagePayload(readFile(resolved))
    if payload.ok:
      result.mimeType = payload.mime
      result.data = payload.data
  except CatchableError:
    discard

proc hydrateMessages*(ws: Workspace, messages: seq[Message]): seq[Message] =
  for msg in messages:
    var parts: seq[ContentBlock] = @[]
    for p in msg.content:
      case p.kind
      of ckImage:
        let img = ws.hydrateImage(p.toImage)
        if img.data.len > 0:
          parts.add image(img)
        else:
          let name = if p.path.len > 0: p.path else: p.mimeType
          parts.add text("[missing image: " & name & "]")
      of ckFile:
        if p.file.data.len > 0 or p.file.path.len == 0:
          parts.add p
        else:
          try:
            var f = p.file
            f.data = encode(readFile(ws.resolve(f.path)))
            if f.mimeType.len == 0:
              f.mimeType = "application/octet-stream"
            parts.add file(f)
          except CatchableError:
            parts.add text("[missing file: " & fileLabel(p.file) & "]")
      of ckToolResult:
        var q = p
        var imgs: seq[ImageContent] = @[]
        for im in p.images:
          let loaded = ws.hydrateImage(im)
          if loaded.data.len > 0:
            imgs.add loaded
        q.images = imgs
        parts.add q
      else:
        parts.add p
    result.add Message(role: msg.role, content: parts)

proc extForMime(mime: string): string =
  case mime
  of "image/jpeg": ".jpg"
  of "image/gif": ".gif"
  of "image/webp": ".webp"
  else: ".png"

proc saveWorkspaceImage*(ws: Workspace, raw: string):
    tuple[ok: bool, mention, err: string] =
  ## Write sniffed image bytes under `.nimlet/clips/` and return an @mention.
  let c = classifyImage(raw)
  if c.mime.len == 0:
    return (false, "", "not an image")
  if not c.ok:
    return (false, "", c.err)
  let dir = ws.root / ".nimlet" / "clips"
  createDir(dir)
  let name = "clip-" & $getCurrentProcessId() & "-" &
    $int(epochTime() * 1000) & extForMime(c.mime)
  writeFile(dir / name, raw)
  (true, "@.nimlet/clips/" & name, "")

proc unquotePath(s: string): string =
  var t = s.strip
  if t.startsWith("file://"):
    t = t["file://".len .. ^1]
  if t.len >= 2 and ((t[0] == '"' and t[^1] == '"') or
      (t[0] == '\'' and t[^1] == '\'')):
    t = t[1 ..< t.len - 1]
  t.strip

proc looksLikeImagePaste(s: string): bool =
  let t = s.strip
  if t.len < 5 or '\n' in t or '\r' in t: return false
  let low = t.toLowerAscii
  low.endsWith(".png") or low.endsWith(".jpg") or low.endsWith(".jpeg") or
    low.endsWith(".gif") or low.endsWith(".webp") or
    t.startsWith("file://") or '/' in t or '\\' in t

proc ingestPastedPath*(ws: Workspace, pasted: string): string =
  ## `@rel` (or a copied clip mention) if `pasted` is a single image path.
  if not looksLikeImagePaste(pasted):
    return
  let path = unquotePath(pasted)
  if path.len == 0:
    return
  var abs = path
  if not path.isAbsolute:
    abs = ws.root / path
  if not fileExists(abs) and fileExists(path):
    abs = path
  if not fileExists(abs) or dirExists(abs):
    return
  var head = newString(16)
  try:
    let f = open(abs)
    let n = f.readBuffer(addr head[0], 16)
    f.close()
    head.setLen(n)
  except CatchableError:
    return
  if sniffImageMime(head).len == 0:
    return
  let raw = readFile(abs)
  if classifyImage(raw).mime.len == 0:
    return
  try:
    let real = expandFilename(abs)
    if real == ws.root or real.startsWith(ws.root & DirSep):
      return "@" & relative(ws, real).canonRel
  except CatchableError:
    discard
  let saved = saveWorkspaceImage(ws, raw)
  if saved.ok: saved.mention else: ""
