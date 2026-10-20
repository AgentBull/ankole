import type { DatabaseView } from '@ankole/applet-sdk/types'
import { z } from 'zod'

const value = z.union([
  z.string(),
  z.number(),
  z.boolean(),
  z.null(),
  z.array(z.unknown()),
  z.record(z.string(), z.unknown())
])
const configSchema = z.looseObject({
  type: z.enum(['grid', 'kanban', 'gallery']).optional(),
  visible_fields: z.array(z.string()).optional(),
  group_field_id: z.string().optional(),
  cover_field_id: z.string().optional(),
  filter: z
    .object({
      conjunction: z.enum(['and', 'or']),
      conditions: z.array(
        z.object({
          field_id: z.string(),
          operator: z.enum(['is', 'contains', 'is_empty', 'is_not_empty', 'gt', 'gte', 'lt', 'lte', 'text_contains']),
          value: value.optional()
        })
      )
    })
    .optional(),
  sort: z.array(z.object({ field_id: z.string(), direction: z.enum(['asc', 'desc']) })).optional()
})

export type ViewConfig = z.infer<typeof configSchema>
export type ConfiguredView = Omit<DatabaseView, 'config'> & { config: ViewConfig }
export const parseViewConfig = (input: unknown) => configSchema.safeParse(input)

export type EmbedView = { kind: 'saved'; id?: string } | { kind: 'inline'; config: ViewConfig } | { kind: 'invalid' }

/** The document stores either a saved view ID or a JSON configuration. */
export function parseEmbedView(raw?: string): EmbedView {
  if (!raw?.trim()) return { kind: 'saved' }
  const text = raw.trim()
  if (!text.startsWith('{') && !text.startsWith('[')) return { kind: 'saved', id: text }
  try {
    const result = parseViewConfig(JSON.parse(text))
    return result.success ? { kind: 'inline', config: result.data } : { kind: 'invalid' }
  } catch {
    return { kind: 'invalid' }
  }
}
