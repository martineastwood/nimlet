## Small, config-backed keybinding matcher for the interactive editor.

import std/[json, strutils]
import nimterm/keys

proc parseKeySpec*(value: string): Key =
  let parts = value.strip.toLowerAscii.split('+')
  if parts.len == 0: return keyNone
  let name = parts[^1]
  let ctrl = "ctrl" in parts[0 ..< parts.high]
  let alt = "alt" in parts[0 ..< parts.high]
  let shift = "shift" in parts[0 ..< parts.high]
  if ctrl and name.len == 1 and name[0] in {'a' .. 'z'}:
    return case name[0]
      of 'a': keyCtrlA
      of 'b': keyCtrlB
      of 'c': keyCtrlC
      of 'd': keyCtrlD
      of 'e': keyCtrlE
      of 'f': keyCtrlF
      of 'g': keyCtrlG
      of 'h': keyCtrlH
      of 'k': keyCtrlK
      of 'l': keyCtrlL
      of 'n': keyCtrlN
      of 'o': keyCtrlO
      of 'p': keyCtrlP
      of 'q': keyCtrlQ
      of 'r': keyCtrlR
      of 's': keyCtrlS
      of 't': keyCtrlT
      of 'u': keyCtrlU
      of 'v': keyCtrlV
      of 'w': keyCtrlW
      of 'x': keyCtrlX
      of 'y': keyCtrlY
      of 'z': keyCtrlZ
      else: keyNone
  if alt:
    return case name
      of "b", "left": keyAltB
      of "d": keyAltD
      of "f", "right": keyAltF
      of "j": keyAltJ
      of "up": keyAltUp
      of "enter", "return": keyAltEnter
      else: keyNone
  if shift:
    return case name
      of "enter", "return": keyShiftEnter
      of "tab": keyShiftTab
      else: keyNone
  case name
  of "escape", "esc": keyEscape
  of "enter", "return": keyEnter
  of "backspace": keyBackspace
  of "delete": keyDelete
  of "left": keyLeft
  of "right": keyRight
  of "up": keyUp
  of "down": keyDown
  of "home": keyHome
  of "end": keyEnd
  of "pageup": keyPageUp
  of "pagedown": keyPageDown
  of "tab": keyTab
  of "shift+enter": keyShiftEnter
  else: keyNone

proc defaultKeySpecs(action: string): seq[string] =
  case action
  of "app.editor.external": @[
    "ctrl+g"]
  of "tui.editor.undo": @[
    "ctrl+z"]
  of "tui.editor.deleteWordBackward": @[
    "ctrl+w"]
  of "tui.editor.deleteWordForward": @[
    "alt+d"]
  of "tui.editor.deleteCharBackward": @[
    "backspace"]
  of "tui.editor.deleteCharForward": @[
    "delete", "ctrl+d"]
  of "tui.editor.deleteToLineStart": @[
    "ctrl+u"]
  of "tui.editor.deleteToLineEnd": @[
    "ctrl+k"]
  of "tui.editor.yank": @[
    "ctrl+y"]
  of "tui.editor.cursorLeft": @[
    "left", "ctrl+b"]
  of "tui.editor.cursorRight": @[
    "right", "ctrl+f"]
  of "tui.editor.cursorWordLeft": @[
    "alt+b"]
  of "tui.editor.cursorWordRight": @[
    "alt+f"]
  of "tui.editor.cursorLineStart": @[
    "home", "ctrl+a"]
  of "tui.editor.cursorLineEnd": @[
    "end", "ctrl+e"]
  of "tui.editor.cursorUp": @[
    "up"]
  of "tui.editor.cursorDown": @[
    "down"]
  of "tui.editor.historyPrevious": @[
    "ctrl+p"]
  of "tui.editor.historyNext": @[
    "ctrl+n"]
  of "tui.input.newLine": @[
    "shift+enter", "alt+j"]
  of "tui.input.submit": @[
    "enter"]
  of "tui.input.tab": @[
    "tab"]
  of "app.interrupt": @[
    "escape"]
  of "app.clear": @[
    "ctrl+c"]
  of "app.message.followUp": @[
    "alt+enter"]
  of "app.message.dequeue": @[
    "alt+up"]
  of "app.thinking.cycle": @[
    "shift+tab"]
  else: @[]

proc configuredSpecs(keybindings: JsonNode, action: string): tuple[found: bool,
                                                                    specs: seq[string]] =
  if keybindings.isNil or keybindings.kind != JObject or action notin keybindings:
    return
  result.found = true
  let node = keybindings[action]
  case node.kind
  of JString:
    result.specs = @[node.getStr]
  of JArray:
    for value in node:
      if value.kind == JString: result.specs.add value.getStr
  else:
    discard

proc bindingMatches*(keybindings: JsonNode, action: string, key: Key): bool =
  let configured = configuredSpecs(keybindings, action)
  let specs = if configured.found: configured.specs else: defaultKeySpecs(action)
  for spec in specs:
    if parseKeySpec(spec) == key: return true

proc editorKey*(keybindings: JsonNode, key: Key): Key =
  ## Map a configured editor action back to the canonical InputWidget event.
  const actions = [
    ("tui.editor.undo", keyCtrlZ),
    ("tui.editor.deleteCharBackward", keyBackspace),
    ("tui.editor.deleteCharForward", keyDelete),
    ("tui.editor.deleteWordBackward", keyCtrlW),
    ("tui.editor.deleteWordForward", keyAltD),
    ("tui.editor.deleteToLineStart", keyCtrlU),
    ("tui.editor.deleteToLineEnd", keyCtrlK),
    ("tui.editor.yank", keyCtrlY),
    ("tui.editor.cursorLeft", keyLeft),
    ("tui.editor.cursorRight", keyRight),
    ("tui.editor.cursorWordLeft", keyAltB),
    ("tui.editor.cursorWordRight", keyAltF),
    ("tui.editor.cursorLineStart", keyHome),
    ("tui.editor.cursorLineEnd", keyEnd),
    ("tui.editor.cursorUp", keyUp),
    ("tui.editor.cursorDown", keyDown),
    ("tui.editor.historyPrevious", keyCtrlP),
    ("tui.editor.historyNext", keyCtrlN),
    ("tui.input.newLine", keyShiftEnter),
    ("tui.input.newLine", keyAltJ),
    ("tui.input.submit", keyEnter),
    ("tui.input.tab", keyTab),
  ]
  for (action, canonical) in actions:
    if bindingMatches(keybindings, action, key): return canonical
    if configuredSpecs(keybindings, action).found:
      for spec in defaultKeySpecs(action):
        if parseKeySpec(spec) == key: return keyNone
  key
