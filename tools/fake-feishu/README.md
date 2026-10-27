# fake-feishu

`fake-feishu` is a standalone simulated Feishu/Lark platform with an interactive
CLI. You can use it to test a local Ankole instance end to end without opening
the Feishu web client: the control plane connects to `fake-feishu` just as it
connects to the real Feishu service, while you act as the chat user from your
terminal.

Because `fake-feishu` shares its core implementation in `platform/` with the
end-to-end test suites (`tools/e2e`), both the CLI and automated tests run
against the exact same simulation: PBBP2 WebSocket frames, authentication with
tenant tokens, endpoints for messages, reactions, files, and images, a chat
directory, and CardKit streaming cards complete with `sequence` and `uuid`
conflict codes (`300317`, `200770`, `200740`).

## Quick start

1. Start the simulated platform (by default, it auto-registers unknown app
   credentials and seeds a `"General"` group chat plus one P2P chat per app):

   ```bash
   tools/fake-feishu/run serve
   ```

2. Point your development control plane at the server and start Ankole as usual
   (this URL override takes effect only in the `:dev` environment):

   ```bash
   export ANKOLE_LARK_BASE_URL_OVERRIDE=http://127.0.0.1:7788
   ```

   Configure at least one enabled Lark binding in Ankole. Any `appID`/`appSecret`
   pair works out of the box because the server accepts new credentials on first
   authentication unless you pass `--strict-apps`.

3. Chat with the bot from a second terminal:

   ```bash
   tools/fake-feishu/run repl
   ```

   The REPL sends each input line as `"Alice"`, automatically mentions the bot
   in group chats (prefix a line with `!` to omit the mention), and streams the
   bot's replies—including live CardKit card updates—straight to your terminal.

Run `tools/fake-feishu/run --help` to inspect the full command set: one-shot
`send`, `ls`, `tail`, reactions, message recalls, card button clicks (`click`),
file and image transfers (`send --file/--image`, `download`), chat management,
and one-shot fault injection (`fault post_message --rate-limited`).

When running the local control plane inside a container, pass
`serve --ip 0.0.0.0` and point Ankole at a host-reachable base URL such as
`http://host.docker.internal:7788` on Docker Desktop; the server derives the
WebSocket discovery URL from the `Host` and port of the incoming discovery
request.

## What it simulates

- WebSocket long-connection discovery, PBBP2 frames, ping/pong heartbeats, and
  event acknowledgments.
- `im/v1` messages (send, reply, edit, delete), reactions, files, images,
  message resources, and message read-back.
- `im/v1/chats` list, info, and member endpoints with pagination backed by the
  in-memory chat registry, routing events to every app whose bot belongs to the
  chat.
- CardKit flows: card creation, streaming element content, `batch_update`, and
  card settlement. Passing `--no-cardkit` causes card creation to return code
  `200860` so that the Lark adapter exercises its plain-text fallback path (the
  default in `tools/e2e`).
- Webhook/WebSocket events: `im.message.receive_v1`, `im.message.recalled_v1`,
  reaction created/deleted, chat member added/removed, `im.chat.updated_v1`, and
  `card.action.trigger`.

`contact/v3` directory synchronization and OAuth user identity are not
simulated. All state lives in memory, so restarting the server resets the
platform to a clean slate.

## Layout

- `platform/` — Core simulation modules (`FakeFeishu.State/Router/WebSocketHandler`),
  which are also compiled into the control plane's `:test` environment for the
  end-to-end suites.
- `lib/` — Standalone server (`Standalone`, `EventHub`, and `AdminRouter` under
  `/sim/v1`) together with the CLI commands.
- `run` — Wrapper script that builds the escript on demand and runs it.

Run `mix test` inside `tools/fake-feishu` to execute the unit tests for the
standalone platform. To run the full round-trip integration test covering the
real SDK WebSocket client and CLI, execute
`app/control_plane/integration/fake_feishu_standalone_e2e_test.exs` from
`app/control_plane`. The standalone escript depends only on the frame codec and
its HTTP server libraries.
