# fake-feishu

A standalone fake Feishu/Lark platform with a CLI. Use it to test a local
Ankole instance end to end without the Feishu web client: the control plane
connects to it as if it were the real platform, and you play the user side
from the terminal.

The platform core in `platform/` is shared with the e2e suites
(`tools/e2e`), so the CLI and the suites exercise the same simulation: real
PBBP2 WS frames, tenant token auth, message/reaction/file/image endpoints,
chat directory, and CardKit streaming cards with real `sequence`/`uuid`
conflict codes (300317, 200770, 200740).

## Quick start

1. Start the platform (auto-registers unknown app credentials and seeds a
   "General" group plus one p2p chat per app):

   ```bash
   tools/fake-feishu/run serve
   ```

2. Point the dev control plane at it and start it as usual. The override only
   works in the `:dev` environment:

   ```bash
   export ANKOLE_LARK_BASE_URL_OVERRIDE=http://127.0.0.1:7788
   ```

   The instance needs one enabled Lark binding; its `appID`/`appSecret` can
   be any pair, because the fake accepts them on first authentication
   (`--strict-apps` turns that off).

3. Talk to the bot from a second terminal:

   ```bash
   tools/fake-feishu/run repl
   ```

   The repl sends each line as "Alice", mentions the bot in group chats
   (prefix a line with `!` to skip the mention), and streams the bot's
   replies — including live CardKit card updates — into the terminal.

`tools/fake-feishu/run --help` lists every command: one-shot `send`, `ls`,
`tail`, reactions, recalls, card button clicks (`click`), file and image
exchange (`send --file/--image`, `download`), chat management, and one-shot
fault injection (`fault post_message --rate-limited`).

## What it simulates

- WS long-connection discovery, PBBP2 frames, ping/pong, event acks.
- `im/v1` messages (send/reply/edit/delete), reactions, files, images,
  resources, message read-back.
- `im/v1/chats` list/info/members with pagination, backed by the chat
  registry; events route to the apps whose bots are chat members.
- CardKit: card creation, element content streaming, `batch_update`, and the
  settle flow. `--no-cardkit` makes card creation answer code 200860 so the
  adapter exercises its plain-text fallback (the e2e default).
- Events: `im.message.receive_v1`, `im.message.recalled_v1`, reaction
  created/deleted, chat member added/removed, `im.chat.updated_v1`, and
  `card.action.trigger`.

Not simulated: `contact/v3` directory sync and OAuth user identity. State is
in memory; a restart gives an empty platform.

## Layout

- `platform/` — the fake platform (`FakeFeishu.State/Router/WebSocketHandler`).
  Also compiled into the control plane `:test` environment for the e2e suites.
- `lib/` — standalone server (`Standalone`, `EventHub`, `AdminRouter` under
  `/sim/v1`) and the CLI.
- `run` — builds the escript when needed and executes it.
