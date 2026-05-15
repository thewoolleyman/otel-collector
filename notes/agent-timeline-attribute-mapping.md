# Mapping Claude Code spans → Honeycomb Agent Timeline

## What Honeycomb's Agent Timeline requires

Every span needs these three attributes:

| Attribute | Notes |
|---|---|
| `gen_ai.conversation.id` | Groups all spans within one agent conversation. |
| `gen_ai.agent.name` | Display name. Falls back to "Unknown" if missing. Sub-agents should use their own distinct names. |
| `gen_ai.operation.name` | Must be one of: `invoke_agent`, `create_agent`, `chat`, `text_completion`, `generate_content`, `embeddings`, `execute_tool`. |

Span **name** must also follow a pattern:

| Span type | `gen_ai.operation.name` | Span name pattern |
|---|---|---|
| Agent | `invoke_agent` or `create_agent` | `invoke_agent {agent_name}` |
| LLM call | `chat`, `text_completion`, ... | `chat {model}` |
| Tool call | `execute_tool` | `execute_tool {tool_name}` |

Recommended extras (Claude Code already supplies most of these): `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.response.finish_reasons`, `gen_ai.tool.name`, `gen_ai.tool.call.id`.

## What Claude Code actually sends today

Verified against trace `51e48a330e17ce8f7e19429d248256eb` in `claude-code-usage`:

- `service.name = claude-code`
- Span hierarchy (no rewriting):
  ```
  claude_code.interaction
  ├── claude_code.llm_request
  ├── claude_code.hook
  └── claude_code.tool
      ├── claude_code.tool.blocked_on_user
      └── claude_code.tool.execution
  ```
- Already present (good): `session.id`, `gen_ai.system`, `gen_ai.request.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`, `model`, `input_tokens`, `total_tokens`, `tool_name`, `tool_use_id`, `agent_id`, `parent_agent_id`, `interaction.sequence`, `span.type`.
- Missing for the timeline: `gen_ai.conversation.id`, `gen_ai.agent.name`, `gen_ai.operation.name`, and the renamed span names.

## Proposed collector transformations

All applied as `transform` processor statements keyed on `span.name` (which the doc says always equals `span.type`).

| Source | Set `gen_ai.operation.name` | Rewrite span name to |
|---|---|---|
| `claude_code.interaction` | `invoke_agent` | `invoke_agent {agent.name}` |
| `claude_code.llm_request` | `chat` | `chat {model}` |
| `claude_code.tool` | `execute_tool` | `execute_tool {tool_name}` |
| `claude_code.tool.execution` | *(see open question)* | *(see open question)* |
| `claude_code.tool.blocked_on_user` | leave as-is | leave as-is |
| `claude_code.hook` | leave as-is | leave as-is |

Unconditional on every span:

- `gen_ai.conversation.id` ← `session.id`
- `gen_ai.agent.name` ← `agent_id` if present, else `"Claude Code"` (or `service.name`).

## Open questions

1. **`claude_code.tool` vs `claude_code.tool.execution`.** The parent `claude_code.tool` span represents the whole tool call (including the wait-for-permission child). Honeycomb expects one `execute_tool` span per tool call. We probably want the parent to be the timeline node and leave `.execution` and `.blocked_on_user` as nested detail. Decide once we see how the timeline renders both options.
2. **Sub-agent naming.** Claude Code sets `agent_id` on LLM-request spans but I haven't confirmed whether the `claude_code.interaction` span itself carries `agent_id` for sub-agent interactions, or just for nested LLM/tool spans. Need to verify against a Task-tool trace before deciding the agent-name expression.
3. **`gen_ai.tool.name`.** Worth also copying `tool_name` → `gen_ai.tool.name` for the recommended-attrs path.
