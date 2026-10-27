# Ankole Standard DingTalk AI Card Template

Ankole delivers streaming AI replies on DingTalk through a **template-hosted AI
card**: the card layout lives on the DingTalk Card Platform (卡片平台), and
Ankole injects a fixed set of variables into each card instance. Operators build
this template once per DingTalk organization, publish it, and paste its
`cardTemplateId` into the chat binding. If `cardTemplateId` is left empty,
Ankole disables card streaming and sends AI replies as plain Markdown messages.

To create the template in the DingTalk developer console:

1. Open **卡片平台** (Card Platform) → **新建模板** → choose the **AI 卡片**
   category, which provides DingTalk's native `处理中` / `输入中` / `完成` /
   `出错` lifecycle.
2. Add every variable listed in the schema below using the exact variable names
   (变量名). Because Ankole writes all of these variables on every card
   instance, omitting any variable causes the card to fail closed.
3. Configure the `输入中`, `完成`, and `出错` layouts in the AI card component.
   Bind a Markdown component to `answer` in every layout that displays the
   reply, and enable streaming on the `输入中` Markdown component. If interactive
   decision buttons should stay visible both during and after generation, place
   the `actions` region in both `输入中` and `完成`.
4. Link the template to the enterprise-internal app that owns the robot, publish
   the template, and copy its template ID into the binding's `cardTemplateId`.

DingTalk switches layouts automatically through its native AI card lifecycle, so
do not create or bind a `flowStatus` or `flowStatusVar` template variable. See
the [AI card template guide](https://open.dingtalk.com/document/development/ai-card-template)
and the
[streaming update API](https://developers.dingtalk.com/document/development/api-streamingupdate)
for platform details.

Configure the template manually from the table below (exact UI labels in Card
Platform can vary across DingTalk releases).

## Variable schema

| Variable (变量名) | Type | Content that Ankole writes |
|---|---|---|
| `state` | text | Status line: shows the live tool label or `输入中` while running, then `已完成` / `出错` / `已停止` / `等待输入`. Once a long reply rolls over to a continuation card, the closed card displays `回答继续于下一张卡片`. |
| `answer` | **streaming Markdown** | The reply body, updated via `PUT /v1.0/card/streaming` with `isFull: true`. This is the only variable updated at streaming cadence. |
| `thought` | Markdown, collapsed section | Transient reasoning draft while the turn is running; streamed on its own key and cleared at completion or refresh. Render it inside a collapsed section. |
| `plan` | text | `执行计划 · completed/total` header followed by one `- [ ] item` line per step |
| `activity` | text, collapsed section | Active tool calls, formatted as one `- … label` line per entry and cleared at completion |
| `receipts` | text | Side-effect receipts, formatted as one `- ✅ summary（scope）` line per entry |
| `actions` | **JSON string** | Interactive controls for the action region (see below), or `""` when none are active |
| `meta` | text | Curated turn metadata joined with ` · `: trigger reason, card position in the continuation chain, recalled-memory and attachment counts, and elapsed time |

`answer` must be bound to a Markdown-rendering variable: DingTalk requires full
overwrites (`isFull: true`) for streamed Markdown, which matches Ankole's
accumulated-snapshot model. When a reply exceeds the single-card size budget,
Ankole seals the current card with `isFinalize` and continues streaming on a
newly delivered continuation card; sealed cards are never modified again.

## Native card state

While Ankole sends streaming updates without a terminal flag, DingTalk keeps the
card in its `输入中` state. Sending `isFinalize: true` transitions the card to
`完成`, and sending `isError: true` transitions it to `出错`. When Ankole creates
an interactive card whose content is already complete, it also sends one full
`answer` streaming update with `isFinalize: true` right after creation.

For non-streaming structural fields such as `state`, `plan`, and `actions`,
Ankole sets `cardUpdateOptions.updateCardDataByKey` so DingTalk merges those
keys without clobbering other template data.

## Action area (`actions` variable)

`actions` holds a JSON array that the template's action region binds to. Each
element has this shape:

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
    "sourceSignalId": "…"
  }
}
```

Free-text controls also include `"input": {"name", "placeholder", "required"}`
and set `value.answerKind` to `"free_text"`; render them as a text input paired
with a submit button.

The template must honor one callback rule: **every button must submit its
`value` object verbatim as the callback parameters**. Because Ankole creates
card instances with `callbackType: "STREAM"`, button clicks arrive over the same
Stream connection on topic `/v1.0/card/instances/callback`, and the adapter
forwards the untouched `value` map into Ankole's portable interaction protocol.
Card buttons never carry authorization on their own: the callback path
re-verifies the clicking user's Principal, and if a clicked control refers to an
interaction that is already settled or expired, the adapter acknowledges the
callback and ignores it. Inbound parsing accepts DingTalk's
`content → cardPrivateData → params` envelope as well as string-encoded integer
fields.
