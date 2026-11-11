# Chat `ui` blocks

A reply in a native Ankole room may contain fenced code blocks whose language is `ui`. Pod renders each block as a small interactive UI inside the message. Each line of a block is one RFC 6902 JSON Patch `add` operation, and together the lines build a flat UI spec:

```ui
{"op":"add","path":"/root","value":"main"}
{"op":"add","path":"/elements/main","value":{"type":"Stack","props":{},"children":["region","east","west","more"]}}
{"op":"add","path":"/state/region","value":"east"}
{"op":"add","path":"/elements/region","value":{"type":"ToggleGroup","props":{"options":[{"value":"east","label":"East"},{"value":"west","label":"West"}],"value":{"$bindState":"/region"}},"children":[]}}
{"op":"add","path":"/elements/east","value":{"type":"Stat","props":{"label":"East revenue","value":"1.28M","delta":"+12%"},"visible":{"$state":"/region","eq":"east"},"children":[]}}
{"op":"add","path":"/elements/west","value":{"type":"Stat","props":{"label":"West revenue","value":"0.94M","delta":"-3%"},"visible":{"$state":"/region","eq":"west"},"children":[]}}
{"op":"add","path":"/elements/more","value":{"type":"Button","props":{"label":"Break down by team","variant":"outline"},"on":{"press":{"action":"reply","params":{"text":"Break the east region down by team"}}},"children":[]}}
```

## When to write one

- Write a block only when the turn context says `ui_blocks: interactive`. External IM channels show a block as raw code, and a Pod page shows it as a code block.
- Use a block when the reader benefits from switching, sorting or comparing, or from a chart or headline numbers. Use plain Markdown for everything else.
- Write the prose of the reply outside the block as ordinary Markdown, and state the conclusion there so that the reply still reads well as plain text. Begin the reply with that prose, because conversation lists preview the start of a reply.
- Put only facts from the conversation or from your tools into a block. Never invent sample data.
- A block holds view state only. Ask a question you wait on with the `clarify` tool, and build an Applet for anything that reads or writes data.

## Format

- Write one complete JSON object per line, with no blank lines, comments or wrapped lines.
- Set `/root` first, then add each element at `/elements/<key>`, parents before children. Add each `/state/<name>` value before the first element that reads it.
- Every element has `type`, `props` and `children`. `children` lists element keys in order and is `[]` for a leaf. Every key in `children` must be defined in the same block, and every element must be reachable from the root.
- `visible` and `on` are fields of the element, beside `props`, never inside it.
- State paths are JSON Pointers such as `/region`. A prop reads state with `{"$state": "/path"}`, and `ToggleGroup` reads and writes its `value` with `{"$bindState": "/path"}`.
- `visible` takes `{"$state": "/path", "eq": "value"}` (also `neq`, `gt`, `gte`, `lt`, `lte`, or no operator for truthiness; add `"not": true` to invert), or a list of such conditions that must all hold.
- `on` maps an event name to `{"action": "<name>", "params": {...}}`. `Button` emits `press`.
- Keep a block under about 40 elements, and inline at most 50 table or chart rows.
- Use only what this reference describes. Pod shows a block as code when it names an unknown component, gives a component invalid props, leaves a child undefined, nests an element inside itself, expands to more than 500 elements, binds an action other than `setState` and `reply`, or uses `repeat`, `watch` or named slots.

## Components

- `Stack`: `{ direction?: "vertical" | "horizontal", gap?: "sm" | "md" | "lg" }`. Lays children out in a column (default) or a wrapping row. Accepts children.
- `Grid`: `{ columns: number }`. Two to four equal columns that collapse to one in a narrow message. Use for Stat or Card groups. Accepts children.
- `Card`: `{ title?: string, description?: string }`. A bordered group with an optional title and description. Accepts children.
- `Tabs`: `{ tabs: Array<{ value: string, label: string }> }`. Tabbed sections; the first tab starts open. Children are TabPanel elements, one per tab value. Accepts children.
- `TabPanel`: `{ value: string }`. The content of one tab. Only valid as a child of Tabs. Accepts children.
- `Accordion`: `{  }`. Collapsible sections that start closed. Children are AccordionItem elements. Accepts children.
- `AccordionItem`: `{ title: string }`. One collapsible section. Only valid as a child of Accordion. Accepts children.
- `Text`: `{ text: string, tone?: "default" | "secondary", weight?: "normal" | "medium" }`. A line or short paragraph of plain text. Markdown is not parsed.
- `Badge`: `{ text: string, variant?: "secondary" | "info" | "success" | "warning" | "destructive" | "outline" }`. A short status label.
- `Stat`: `{ label: string, value: string | number, delta?: string | number, caption?: string, sparkline?: Array<number> }`. One headline number with an optional change such as "+12%" (its sign picks the colour) and a small trend line.
- `Table`: `{ columns: Array<{ key: string, label: string, align?: "start" | "end" }>, rows: Array<Record<string, string | number | boolean>>, sortable?: boolean }`. A data table. Each row maps column keys to a string, number, boolean or null. With sortable, the reader sorts by clicking a column header. Align numbers to the end.
- `Chart`: `{ type: "column" | "bar" | "line" | "area" | "pie" | "donut", data: Array<Record<string, string | number | boolean>>, xField: string, yField: string, seriesField?: string, title?: string, stacked?: boolean }`. A chart over inline rows. xField names the category or time column, yField the numeric column, and seriesField an optional column that splits the rows into series. For pie and donut, xField names the slice.
- `Progress`: `{ label?: string, value: number }`. A progress bar from 0 to 100.
- `Alert`: `{ title?: string, text: string, variant?: "default" | "warning" | "destructive" }`. A highlighted note, warning or error.
- `Button`: `{ label: string, variant?: "outline" | "ghost" }`. A button that emits `press`; outline by default.
- `ToggleGroup`: `{ options: Array<{ value: string, label: string }>, value?: string | { $bindState: string } }`. A segmented single choice. Bind `value` to a state path and switch other elements with `visible`.

## Actions

- `setState`: `{ statePath: string, value: any }`. Sets the value at a state path. Use it with `visible` to switch what the block shows.
- `reply`: `{ text: string }`. Puts text into the Human's message composer as a follow-up for them to send. Write it as the Human would say it.
