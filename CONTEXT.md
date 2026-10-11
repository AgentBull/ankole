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

- `Signal Binding` in code and APIs is **Signal Routing Rule** in English
  interfaces and **信号路由规则** in Chinese interfaces.
- `Channel Provider` is **Channel Provider** in English and **聊天渠道** in
  Chinese.
- A **site** is one Ankole deployment and its infrastructure. A **tenant** is one
  organization and its data inside that site. Keep platform-specific terms such
  as a Microsoft tenant or Lark tenant token distinct from an Ankole tenant.
