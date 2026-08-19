# Ankole Standard DingTalk AI Card Template

Ankole delivers streaming AI replies on DingTalk through a **template-hosted AI
card**: the card layout lives on the DingTalk card platform (卡片平台) and
Ankole only injects a fixed variable set into card instances. The operator
builds this template once per DingTalk organization, publishes it, and pastes
its `cardTemplateId` into the chat binding. An empty `cardTemplateId` disables
card streaming — AI replies degrade to plain Markdown messages.

Build steps (DingTalk developer console):

1. Open 卡片平台 (Card Platform) → 新建模板 → choose the **AI 卡片** category —
   this card kind carries DingTalk's native 处理中 / 输入中 / 完成 / 出错
   lifecycle.
2. Add the variables below with exactly these names (变量名). The card fails
   closed if a variable is missing: Ankole writes it on every instance.
3. Configure the 输入中, 完成, and 出错 layouts in the AI card component. Bind a
   Markdown component to `answer` in every layout that must show the reply, and
   enable streaming for the 输入中 component. Put the `actions` area in both
   输入中 and 完成 if decision buttons must stay visible.
4. Associate the template with the enterprise-internal app that owns the robot,
   publish it, and copy the template id into the binding's `cardTemplateId`.

DingTalk selects the active layout from its native AI card lifecycle. Do not
create or bind a `flowStatus` or `flowStatusVar` template variable. See the
[AI card template guide](https://open.dingtalk.com/document/development/ai-card-template)
and the
[streaming update API](https://developers.dingtalk.com/document/development/api-streamingupdate).

Build the template manually from the table below. Card Platform control labels
can differ between DingTalk releases.

## Variable schema

| Variable (变量名) | Type | Content Ankole writes |
|---|---|---|
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

## Native card state

Ankole does not write a custom state selector. A streaming update without a
terminal flag keeps the card in DingTalk's input lifecycle. `isFinalize: true`
moves it to 完成, and `isError: true` moves it to 出错. A completed interactive
card also sends one full `answer` update with `isFinalize: true` after creation.

Structural updates use `cardUpdateOptions.updateCardDataByKey` to merge fields
such as `state`, `plan`, and `actions`. This option preserves other template
data, but it does not select the AI card state.

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
