import { z } from 'zod'
import { ModelIntegerID } from '../../core/model-integer-id'
import { CLILabel } from '../primitives'

const CreateWebhookCommand = z.object({
  operation: z.literal('create'),
  label: CLILabel,
  mode: z.enum(['one_shot', 'standing']),
  expires_at: z.string().trim().min(1),
  automation_job_id: ModelIntegerID.optional()
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
