---
name: lark-im
description: "Operate Lark as this digital employee's application bot: messages and chats, contacts, calendars, video meetings, in-meeting bot actions, and Minutes. Use for Lark cloud communication work; never for local document files."
default_enabled: false
category: productivity
execution_profile: lark-cli-bot
tags: [lark, im, contact, calendar, vc, minutes]
metadata:
  upstream: https://github.com/larksuite/cli/tree/v1.0.69/skills
  upstream_tag: v1.0.69
  modified_for: Ankole bot-only signal-bound runtime
---

# Lark IM and collaboration

Use `lark-cli` with the application bot identity already supplied by the current Agent's Lark signal binding. This skill never creates credentials, starts an authorization flow, or acts as a human user.

Before the first command, read [references/bot-runtime.md](references/bot-runtime.md). Then read only the domain reference needed for the task:

- Messages, chats, members, contacts, and directories: [references/im-contact.md](references/im-contact.md)
- Calendars, events, attendees, and free/busy: [references/calendar.md](references/calendar.md)
- Video meetings, in-meeting actions, recordings metadata, and Minutes: [references/meetings-minutes.md](references/meetings-minutes.md)
- Capability limits and permission failures: [references/unsupported-and-permissions.md](references/unsupported-and-permissions.md)

## Routing rules

- An inbound signal reply belongs to the Signals Gateway. Use this skill when the Agent must initiate a new message, send to another chat or person, search communication history, or manage Lark collaboration resources.
- Use Contact only to verify a known stable `open_id`, `user_id`, or `union_id`. If a person or destination is ambiguous, request a stable user or `chat_id`; the bot-only Contact surface cannot search by display name, email, or phone.
- Treat message sends, membership changes, event changes, meeting joins/leaves, and transcript mutations as writes. Inspect command help and use `--dry-run` when the target or payload is uncertain.
- If the task needs cloud documents, spreadsheets, Base, Wiki, Drive, Slides, Whiteboard, or Lark Markdown, switch to `lark-office-suite`.
- If the task needs tasks, OKRs, or attendance, switch to `lark-oa`.

## Completeness contract

The curated references cover common workflows, but they do not freeze the CLI surface. For any IM, Contact, Calendar, VC, or Minutes operation:

1. Run `lark-cli <service> --help` to find the shortcut or typed resource.
2. Run command-level `--help` and require that the identity line includes `bot`.
3. For typed resources, run `lark-cli schema <service>.<resource>.<method>` before constructing `--data` or `--params`.
4. Execute with `--as bot --format json` and decide success from exit code zero or top-level `ok: true`.

If the installed CLI exposes a bot-capable endpoint not enumerated here, it is supported by this skill. An endpoint that requires a person's identity is unsupported even if a similar Lark web UI feature exists.
