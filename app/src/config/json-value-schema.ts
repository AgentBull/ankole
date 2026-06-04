import { z } from 'zod'
import type { AppConfigJsonValue } from './app-configure'

/**
 * Recursive schema for plugin-owned app-config payloads.
 *
 * The host deliberately validates only JSON compatibility here. Concrete
 * provider/channel shapes belong to the adapter factories, while the app-config
 * store only needs a stable `jsonb` + optional encryption contract.
 */
export const appConfigJsonValueSchema: z.ZodType<AppConfigJsonValue> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(appConfigJsonValueSchema),
    z.record(z.string(), appConfigJsonValueSchema)
  ])
)

export const appConfigJsonRecordSchema = z.record(z.string(), appConfigJsonValueSchema)
