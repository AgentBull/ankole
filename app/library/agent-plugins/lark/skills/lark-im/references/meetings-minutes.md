# VC, meeting agent actions, and Minutes

## Video meetings

The `vc` service (`lark-cli vc --help` lists operations not shown here) includes both ordinary meeting APIs and application-bot meeting actions; there is no separate runtime namespace for the meeting agent.

```bash
lark-cli vc +meeting-list-active --as bot --format json
lark-cli vc meeting get --meeting-id <meeting_id> --with-participants --as bot --format json
lark-cli vc +meeting-events --meeting-id <meeting_id> --as bot --format json
lark-cli vc +meeting-join --meeting-number <meeting_number> --as bot --format json
lark-cli vc +meeting-message-send --meeting-id <meeting_id> --msg-type text --text "I am taking notes" --as bot --format json
lark-cli vc +meeting-leave --meeting-id <meeting_id> --as bot --format json
```

Always inspect shortcut help because meeting identifiers differ: join usually starts from a meeting number, while leave, events, messages, and detail use a meeting ID. Joining or leaving is a write and should name the target meeting explicitly.

For broader VC resources, use `lark-cli vc <resource> <method> --help` and its schema. The bot-capable surface can include meetings, participants, rooms, reservations, recordings metadata, reports, and meeting ability data, subject to tenant scopes and bot membership.

## Minutes

A minute token (`lark-cli minutes --help` lists operations not shown here) normally comes from a Minutes URL or from bot-visible meeting artifacts.

```bash
lark-cli minutes minutes get --minute-token <minute_token> --as bot --format json
lark-cli minutes +download --minute-tokens <minute_token> --output-dir lark-minutes --as bot --format json
```

Use typed resources or raw API mode for bot-capable transcript, media, statistics, and metadata endpoints that have no shortcut. The transcript path below is the official [Minutes transcript export API](https://open.feishu.cn/document/minutes-v1/minute-transcript/get). Keep bot identity explicit:

```bash
lark-cli api GET "/open-apis/minutes/v1/minutes/<minute_token>/transcript" --as bot --format json
```

Only use update, upload, speaker replacement, word replacement, summary, or todo shortcuts when their command help lists bot identity and the requested write is explicit. Downloaded media must use a relative output path.
