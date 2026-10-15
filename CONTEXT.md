# Ankole

Ankole is an Agent system that a site operator runs for organizations, their
employees, Agents, and services. A new site starts with one tenant named `default`.

## Canonical terminology

The user-facing terminology table in the
[Chinese Quickstart](app/website/src/content/docs/quickstart/zh-Hans-CN.mdx#terminology)
and its
[English counterpart](app/website/src/content/docs/quickstart/en-US.mdx#terminology)
is the single source of truth for documentation and interface text.

Use these mappings when code or an API keeps a different internal name:

- `Ankole.Conversations` and `conversations` are **Conversation** / **对话**:
  the shared space and its participants' messages.
- `conversation_messages` are **Message** / **消息**: committed conversation
  records visible to participants.
- `Ankole.Signals` and `signals` are **Signal** / **信号**: durable stimuli from
  messages, time, external events, or task completion.
- `Ankole.Sessions` and `sessions` are **Session** / **执行会话**: the execution
  context, signal queue, and recovery state for one Agent. Each Agent in a
  Conversation has a separate session and model state; its audience is the
  Conversation's participants. A session does not cross conversations.
- `Ankole.Conversations.Delivery` and `deliveries` are **Delivery** / **投递**:
  durable intent, attempts, and results for external messages.
- An **AIGateway conversation** is model session state. Keep its public API name,
  but use **model session state** / **模型会话状态** in architecture explanations.
  It is not a shared Conversation and is not an interface term.
- `Signal Binding` in code and APIs is **Signal Routing Rule** in English
  interfaces and **信号路由规则** in Chinese interfaces.
- `Channel Provider` is **Channel Provider** in English and **聊天渠道** in
  Chinese.
- A **site** is one Ankole deployment and its infrastructure. A **tenant** is one
  organization and its data inside that site. Keep platform-specific terms such
  as a Microsoft tenant or Lark tenant token distinct from an Ankole tenant.
