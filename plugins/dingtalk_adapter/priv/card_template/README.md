# Ankole Standard DingTalk AI Card Template

Ankole delivers streaming AI replies on DingTalk through a **template-hosted AI
card**: the card layout lives on the DingTalk card platform (卡片平台) and
Ankole only injects a fixed variable set into card instances. The operator
builds this template once per DingTalk organization, publishes it, and pastes
its `cardTemplateId` into the chat binding. An empty `cardTemplateId` disables
card streaming — AI replies degrade to plain Markdown messages.

Build steps (DingTalk developer console):

1. Open 卡片平台 (Card Platform) → 新建模板 → choose the **AI 卡片** category —
   the AI card kind carries the native 输入中 / 已完成 / 出错 states that
   Ankole drives through the streaming API (`isFinalize` / `isError`).
2. Add the variables below with exactly these names (变量名). The card fails
   closed if a variable is missing: Ankole writes it on every instance.
3. Associate the template with the enterprise-internal app that owns the robot,
   publish it, and copy the template id into the binding's `cardTemplateId`.

Whether the card platform can import a template as JSON (and the exact control
palette per platform version) is a smoke-test item — see
`internals/docs/DingTalkAdapter.zh.md` §13 items 7–10. Until it is verified,
build the template manually from the table below.

## Variable schema

| Variable (变量名) | Type | Content Ankole writes |
|---|---|---|
| `state` | text | Status line: `输入中` / `已完成` / `出错` / `已停止` / `等待输入` (empty when unknown) |
| `answer` | **streaming Markdown** | The reply body. Written with `PUT /v1.0/card/streaming`, `isFull: true`. This is the only variable updated at streaming cadence. |
| `thought` | Markdown, collapsed section | Transient reasoning draft while the turn is working. Streamed on its own key; always blanked at terminal/refresh. Place it in a folded area. |
| `plan` | text | Task list snapshot, one `- [ ] item` line per entry |
| `activity` | text, collapsed section | Running tool activity, one `- … label` line per entry; blanked at terminal |
| `results` | text | One `- title` line per structured result |
| `receipts` | text | One `- summary` line per side-effect receipt |
| `actions` | **JSON string** | Interactive controls for the action area (below); empty string when none |
| `meta` | text | `key: value` pairs joined with `·` |

`answer` must be a Markdown-rendering variable; the platform mandates
`isFull: true` full overwrites for streamed Markdown, which matches Ankole's
accumulated-snapshot model. One reply may span several cards: past the
single-card source budget Ankole seals the current card (`isFinalize`) and
continues on a freshly delivered continuation card. Sealed cards are never
written again.

## Action area (`actions` variable)

`actions` carries a JSON list the template's action region binds to. Each
element is:

```json
{
  "id": "opt-a",
  "label": "Option A",
  "style": "default",
  "disabled": false,
  "value": {
    "version": "ankole.interactive_output.action.v1",
    "answerKind": "choice",
    "interactionId": "…",
    "interactionVersion": 3,
    "controlId": "choice",
    "selectedOptionId": "opt-a",
    "optionValue": "a",
    "sourceActorEventId": "…"
  }
}
```

A free-text element additionally carries `"input": {"name", "placeholder",
"required"}` and its `value.answerKind` is `"free_text"`; render it as one
input field plus a submit button.

The contract the template must honour: **every button submits its `value` map
verbatim as the callback params**. Ankole creates instances with
`callbackType: "STREAM"`, so the press arrives on the same Stream connection
(topic `/v1.0/card/instances/callback`) and the adapter routes the untouched
`value` into the portable interaction protocol. Buttons are not authorization:
the operator's Principal is re-verified on the callback path, and a control
that no longer answers a pending interaction is acknowledged but ignored.

The exact param passthrough shape of the card platform's dynamic button list is
smoke-test item §13.10. If a platform version cannot forward `value` as params,
record the finding there — the inbound handler already tolerates the
`content → cardPrivateData → params` nesting and string-typed integers.
