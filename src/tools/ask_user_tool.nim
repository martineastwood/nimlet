## Tool definition for model-driven user questions.

import std/[asyncdispatch, json]
import nimgent
import tool

proc makeAskUserTool*(): (ToolDefinition, ToolProc) =
  let definition = ToolDefinition(
    name: "ask_user",
    description: "Ask the user a question with multiple-choice options and an Other free-text option.",
    inputSchema: %*{
      "type": "object",
      "properties": {
        "question": {"type": "string"},
        "options": {"type": "array", "items": {"type": "string"}}
      },
      "required": ["question", "options"]
    })
  let run: ToolProc = proc(input: JsonNode): Future[ToolResult] {.async.} =
    discard input
    return toolFailure("question_unavailable", "User questions are unavailable in this interface.",
      %*{"tool": "ask_user"})
  (definition, run)
