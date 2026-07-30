import { z } from 'zod'

const CreateWebhookCommand = z.object({
  operation: z.literal('create'),
  label: z.string().trim().min(1).max(500),
  mode: z.enum(['one_shot', 'standing']),
  expires_at: z.string().trim().min(1),
  automation_job_id: z.number().int().min(1000).max(Number.MAX_SAFE_INTEGER).optional()
})

const ListWebhooksCommand = z.object({
  operation: z.literal('list'),
  limit: z.number().int().positive().max(100).optional()
})

const CancelWebhookCommand = z.object({
  operation: z.literal('cancel'),
  webhook_endpoint_id: z.uuid()
})

export const WebhookCLICommand = z.discriminatedUnion('operation', [
  CreateWebhookCommand,
  ListWebhooksCommand,
  CancelWebhookCommand
])

export type WebhookCLICommand = z.output<typeof WebhookCLICommand>

export type WebhookCLIResponse = { ok: true; result: Record<string, unknown> } | { ok: false; error: string }
