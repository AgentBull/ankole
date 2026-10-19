import * as v from 'valibot'
import type { DatabaseView } from '@ankole/applet-sdk/types'

const value = v.union([
  v.string(),
  v.number(),
  v.boolean(),
  v.null(),
  v.array(v.unknown()),
  v.record(v.string(), v.unknown())
])
const configSchema = v.looseObject({
  type: v.optional(v.picklist(['grid', 'kanban', 'gallery'])),
  visible_fields: v.optional(v.array(v.string())),
  group_field_id: v.optional(v.string()),
  cover_field_id: v.optional(v.string()),
  filter: v.optional(
    v.object({
      conjunction: v.picklist(['and', 'or']),
      conditions: v.array(
        v.object({
          field_id: v.string(),
          operator: v.picklist([
            'is',
            'contains',
            'is_empty',
            'is_not_empty',
            'gt',
            'gte',
            'lt',
            'lte',
            'text_contains'
          ]),
          value: v.optional(value)
        })
      )
    })
  ),
  sort: v.optional(v.array(v.object({ field_id: v.string(), direction: v.picklist(['asc', 'desc']) })))
})

export type ViewConfig = v.InferOutput<typeof configSchema>
export type ConfiguredView = Omit<DatabaseView, 'config'> & { config: ViewConfig }
export const parseViewConfig = (input: unknown) => v.safeParse(configSchema, input)

export type EmbedView = { kind: 'saved'; id?: string } | { kind: 'inline'; config: ViewConfig } | { kind: 'invalid' }

/** The document stores either a saved view ID or a JSON configuration. */
export function parseEmbedView(raw?: string): EmbedView {
  if (!raw?.trim()) return { kind: 'saved' }
  const text = raw.trim()
  if (!text.startsWith('{') && !text.startsWith('[')) return { kind: 'saved', id: text }
  try {
    const result = parseViewConfig(JSON.parse(text))
    return result.success ? { kind: 'inline', config: result.output } : { kind: 'invalid' }
  } catch {
    return { kind: 'invalid' }
  }
}
