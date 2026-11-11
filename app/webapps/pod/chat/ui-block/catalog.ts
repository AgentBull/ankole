import { defineCatalog, defineSchema, type PromptContext } from '@json-render/core'
import { z } from 'zod'

const cell = z.union([z.string(), z.number(), z.boolean()]).nullable()
const row = z.record(z.string(), cell)

type CatalogData = {
  components: Record<string, { props: z.ZodType; slots?: string[]; description: string }>
  actions: Record<string, { params: z.ZodType; description: string }>
}

const EXAMPLE = [
  '{"op":"add","path":"/root","value":"main"}',
  '{"op":"add","path":"/elements/main","value":{"type":"Stack","props":{},"children":["region","east","west","more"]}}',
  '{"op":"add","path":"/state/region","value":"east"}',
  '{"op":"add","path":"/elements/region","value":{"type":"ToggleGroup","props":{"options":[{"value":"east","label":"East"},{"value":"west","label":"West"}],"value":{"$bindState":"/region"}},"children":[]}}',
  '{"op":"add","path":"/elements/east","value":{"type":"Stat","props":{"label":"East revenue","value":"1.28M","delta":"+12%"},"visible":{"$state":"/region","eq":"east"},"children":[]}}',
  '{"op":"add","path":"/elements/west","value":{"type":"Stat","props":{"label":"West revenue","value":"0.94M","delta":"-3%"},"visible":{"$state":"/region","eq":"west"},"children":[]}}',
  '{"op":"add","path":"/elements/more","value":{"type":"Button","props":{"label":"Break down by team","variant":"outline"},"on":{"press":{"action":"reply","params":{"text":"Break the east region down by team"}}},"children":[]}}'
].join('\n')

/**
 * Writes the Skill reference that teaches an Agent the `ui` block. The component and action lists come from the
 * catalog, and `scripts/ui-block-reference.ts` writes `uiBlockCatalog.prompt()` to the library.
 */
function reference({ catalog, formatZodType }: PromptContext<CatalogData>) {
  const components = Object.entries(catalog.components).map(
    ([name, component]) =>
      `- \`${name}\`: \`${formatZodType(component.props)}\`. ${component.description}${component.slots?.length ? ' Accepts children.' : ''}`
  )
  const actions = Object.entries(catalog.actions).map(
    ([name, action]) => `- \`${name}\`: \`${formatZodType(action.params)}\`. ${action.description}`
  )
  return [
    '# Chat `ui` blocks',
    'A reply in a native Ankole room may contain fenced code blocks whose language is `ui`. Pod renders each block as a small interactive UI inside the message. Each line of a block is one RFC 6902 JSON Patch `add` operation, and together the lines build a flat UI spec:',
    `\`\`\`ui\n${EXAMPLE}\n\`\`\``,
    '## When to write one',
    [
      '- Write a block only when the turn context says `ui_blocks: interactive`. External IM channels show a block as raw code, and a Pod page shows it as a code block.',
      '- Use a block when the reader benefits from switching, sorting or comparing, or from a chart or headline numbers. Use plain Markdown for everything else.',
      '- Write the prose of the reply outside the block as ordinary Markdown, and state the conclusion there so that the reply still reads well as plain text. Begin the reply with that prose, because conversation lists preview the start of a reply.',
      '- Put only facts from the conversation or from your tools into a block. Never invent sample data.',
      '- A block holds view state only. Ask a question you wait on with the `clarify` tool, and build an Applet for anything that reads or writes data.'
    ].join('\n'),
    '## Format',
    [
      '- Write one complete JSON object per line, with no blank lines, comments or wrapped lines.',
      '- Set `/root` first, then add each element at `/elements/<key>`, parents before children. Add each `/state/<name>` value before the first element that reads it.',
      '- Every element has `type`, `props` and `children`. `children` lists element keys in order and is `[]` for a leaf. Every key in `children` must be defined in the same block, and every element must be reachable from the root.',
      '- `visible` and `on` are fields of the element, beside `props`, never inside it.',
      '- State paths are JSON Pointers such as `/region`. A prop reads state with `{"$state": "/path"}`, and `ToggleGroup` reads and writes its `value` with `{"$bindState": "/path"}`.',
      '- `visible` takes `{"$state": "/path", "eq": "value"}` (also `neq`, `gt`, `gte`, `lt`, `lte`, or no operator for truthiness; add `"not": true` to invert), or a list of such conditions that must all hold.',
      '- `on` maps an event name to `{"action": "<name>", "params": {...}}`. `Button` emits `press`.',
      '- Keep a block under about 40 elements, and inline at most 50 table or chart rows.',
      '- Use only what this reference describes. Pod shows a block as code when it names an unknown component, gives a component invalid props, leaves a child undefined, nests an element inside itself, expands to more than 500 elements, binds an action other than `setState` and `reply`, or uses `repeat`, `watch` or named slots.'
    ].join('\n'),
    '## Components',
    components.join('\n'),
    '## Actions',
    [
      '- `setState`: `{ statePath: string, value: any }`. Sets the value at a state path. Use it with `visible` to switch what the block shows.',
      ...actions
    ].join('\n')
  ].join('\n\n')
}

// The spec keeps json-render's React element shape, which `@json-render/react` renders; the prompt is Ankole's own.
const schema = defineSchema(
  s => ({
    spec: s.object({
      root: s.string(),
      elements: s.record(
        s.object({
          type: s.ref('catalog.components'),
          props: s.propsOf('catalog.components'),
          children: s.array(s.string()),
          visible: { ...s.any(), ...s.optional() }
        })
      )
    }),
    catalog: s.object({
      components: s.map({ props: s.zod(), slots: s.array(s.string()), description: s.string() }),
      actions: s.map({ params: s.zod(), description: s.string() })
    })
  }),
  { promptTemplate: reference as (context: PromptContext) => string }
)

/**
 * The vocabulary an Agent may use inside a fenced `ui` block of a chat reply. Component names follow the
 * `@ankole/uikit` exports that Applets import, so a block that outgrows a message reads the same as an Applet.
 *
 * A block holds view state only. A question the Agent waits on belongs to Clarify, a change that needs a
 * Human's authority belongs to an Action Card, and anything that reads or writes data belongs to an Applet.
 */
export const uiBlockCatalog = defineCatalog(schema, {
  components: {
    Stack: {
      props: z.object({
        direction: z.enum(['vertical', 'horizontal']).nullish(),
        gap: z.enum(['sm', 'md', 'lg']).nullish()
      }),
      slots: ['default'],
      description: 'Lays children out in a column (default) or a wrapping row.'
    },
    Grid: {
      props: z.object({ columns: z.number() }),
      slots: ['default'],
      description: 'Two to four equal columns that collapse to one in a narrow message. Use for Stat or Card groups.'
    },
    Card: {
      props: z.object({ title: z.string().nullish(), description: z.string().nullish() }),
      slots: ['default'],
      description: 'A bordered group with an optional title and description.'
    },
    Tabs: {
      props: z.object({ tabs: z.array(z.object({ value: z.string(), label: z.string() })) }),
      slots: ['default'],
      description: 'Tabbed sections; the first tab starts open. Children are TabPanel elements, one per tab value.'
    },
    TabPanel: {
      props: z.object({ value: z.string() }),
      slots: ['default'],
      description: 'The content of one tab. Only valid as a child of Tabs.'
    },
    Accordion: {
      props: z.object({}),
      slots: ['default'],
      description: 'Collapsible sections that start closed. Children are AccordionItem elements.'
    },
    AccordionItem: {
      props: z.object({ title: z.string() }),
      slots: ['default'],
      description: 'One collapsible section. Only valid as a child of Accordion.'
    },
    Text: {
      props: z.object({
        text: z.string(),
        tone: z.enum(['default', 'secondary']).nullish(),
        weight: z.enum(['normal', 'medium']).nullish()
      }),
      description: 'A line or short paragraph of plain text. Markdown is not parsed.'
    },
    Badge: {
      props: z.object({
        text: z.string(),
        variant: z.enum(['secondary', 'info', 'success', 'warning', 'destructive', 'outline']).nullish()
      }),
      description: 'A short status label.'
    },
    Stat: {
      props: z.object({
        label: z.string(),
        value: z.union([z.string(), z.number()]),
        delta: z.union([z.string(), z.number()]).nullish(),
        caption: z.string().nullish(),
        sparkline: z.array(z.number()).nullish()
      }),
      description:
        'One headline number with an optional change such as "+12%" (its sign picks the colour) and a small trend line.'
    },
    Table: {
      props: z.object({
        columns: z.array(z.object({ key: z.string(), label: z.string(), align: z.enum(['start', 'end']).nullish() })),
        rows: z.array(row),
        sortable: z.boolean().nullish()
      }),
      description:
        'A data table. Each row maps column keys to a string, number, boolean or null. With sortable, the reader sorts by clicking a column header. Align numbers to the end.'
    },
    Chart: {
      props: z.object({
        type: z.enum(['column', 'bar', 'line', 'area', 'pie', 'donut']),
        data: z.array(row),
        xField: z.string(),
        yField: z.string(),
        seriesField: z.string().nullish(),
        title: z.string().nullish(),
        stacked: z.boolean().nullish()
      }),
      description:
        'A chart over inline rows. xField names the category or time column, yField the numeric column, and seriesField an optional column that splits the rows into series. For pie and donut, xField names the slice.'
    },
    Progress: {
      props: z.object({ label: z.string().nullish(), value: z.number() }),
      description: 'A progress bar from 0 to 100.'
    },
    Alert: {
      props: z.object({
        title: z.string().nullish(),
        text: z.string(),
        variant: z.enum(['default', 'warning', 'destructive']).nullish()
      }),
      description: 'A highlighted note, warning or error.'
    },
    Button: {
      props: z.object({ label: z.string(), variant: z.enum(['outline', 'ghost']).nullish() }),
      description: 'A button that emits `press`; outline by default.'
    },
    ToggleGroup: {
      props: z.object({
        options: z.array(z.object({ value: z.string(), label: z.string() })),
        value: z.union([z.string(), z.object({ $bindState: z.string() })]).nullish()
      }),
      description: 'A segmented single choice. Bind `value` to a state path and switch other elements with `visible`.'
    }
  },
  actions: {
    reply: {
      params: z.object({ text: z.string() }),
      description:
        "Puts text into the Human's message composer as a follow-up for them to send. Write it as the Human would say it."
    }
  }
})
