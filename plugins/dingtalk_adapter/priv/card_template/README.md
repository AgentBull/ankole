# Ankole Standard DingTalk AI Card Template

Ankole delivers streaming AI replies on DingTalk through a **template-hosted AI
card**: the card layout lives on the DingTalk card platform (卡片平台) and
Ankole only injects a fixed variable set into card instances. The operator
builds this template once per DingTalk organization, publishes it, and pastes
its `cardTemplateId` into the chat binding. An empty `cardTemplateId` disables
card streaming — AI replies degrade to plain Markdown messages.

Build steps (DingTalk developer console):

1. Open 卡片平台 (Card Platform) → 新建模板 → choose the **AI 卡片** category —
   the AI card kind carries the native 输入中 / 已完成 / 出错 states, and its AI
   card container selects which one to show from the `flowStatus` variable.
2. Add the variables below with exactly these names (变量名). The card fails
   closed if a variable is missing: Ankole writes it on every instance.
3. Bind the AI card container's status variable (流程状态 / `flowStatusVar`) to
   `flowStatus`, and keep the 输入中 and 出错 states enabled. A container whose
   status variable is unbound cannot leave the writing state.
4. Associate the template with the enterprise-internal app that owns the robot,
   publish it, and copy the template id into the binding's `cardTemplateId`.

Whether the card platform can import a template as JSON (and the exact control
palette per platform version) is a smoke-test item — see
`internals/docs/DingTalkAdapter.zh.md` §13 items 7–10. Until it is verified,
build the template manually from the table below.

## Variable schema

| Variable (变量名) | Type | Content Ankole writes |
|---|---|---|
| `flowStatus` | text, bound to the AI card container | `2` while the card streams, `3` once it is sealed, `5` when it is sealed as an error |
| `state` | text | Status line: the live tool label or `输入中` while working, then `已完成` / `出错` / `已停止` / `等待输入`. A card the chain rolled past says `回答继续于下一张卡片`. |
| `answer` | **streaming Markdown** | The reply body. Written with `PUT /v1.0/card/streaming`, `isFull: true`. This is the only variable updated at streaming cadence. |
| `thought` | Markdown, collapsed section | Transient reasoning draft while the turn is working. Streamed on its own key; always blanked at terminal/refresh. Place it in a folded area. |
| `plan` | text | `执行计划 · completed/total` header, then one `- [ ] item` line per entry |
| `activity` | text, collapsed section | Running tool activity, one `- … label` line per entry; blanked at terminal |
| `results` | text | One `- title` line per structured result |
| `receipts` | text | One `- ✅ summary（scope）` line per side-effect receipt |
| `actions` | **JSON string** | Interactive controls for the action area (below); empty string when none |
| `meta` | text | Curated metadata joined with ` · `: why the turn was triggered, the card's place in the chain, recalled-memory and attachment counts, elapsed time |

`answer` must be a Markdown-rendering variable; the platform mandates
`isFull: true` full overwrites for streamed Markdown, which matches Ankole's
accumulated-snapshot model. One reply may span several cards: past the
single-card source budget Ankole seals the current card (`isFinalize`) and
continues on a freshly delivered continuation card. Sealed cards are never
written again.

## Card state (`flowStatus`)

The AI card container decides which state to render from `flowStatus`. Closing
the stream with `isFinalize` or `isError` does not move it, so Ankole writes the
value itself on every `PUT /v1.0/card/instances` call, and every such call sets
`cardUpdateOptions.updateCardDataByKey` so the write merges instead of replacing
the whole variable map. A full replacement would clear `flowStatus`, leaving the
container with no state to render and the card visibly blank.

The platform's values are `1` pending, `2` writing, `3` done, `4` doing, and `5`
failed. Ankole uses only `2`, `3`, and `5`; the template does not need to render
the other two.

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
