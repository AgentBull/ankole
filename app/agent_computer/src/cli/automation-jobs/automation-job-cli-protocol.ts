import { z } from 'zod'

const ModelIntegerID = z.number().int().min(1000).max(Number.MAX_SAFE_INTEGER)

const CreateAutomationJobCommand = z.object({
  operation: z.literal('create'),
  directory_path: z.string().trim().min(1).max(4096),
  cwd: z.string().trim().min(1).max(4096),
  label: z.string().trim().min(1).max(500),
  wake_on_failure: z.boolean()
})

const ListAutomationJobsCommand = z.object({
  operation: z.literal('list'),
  limit: z.number().int().positive().max(500).optional()
})

const ShowAutomationJobCommand = z.object({
  operation: z.literal('show'),
  automation_job_id: ModelIntegerID,
  runs: z.number().int().positive().max(100).optional()
})

const CancelAutomationJobCommand = z.object({
  operation: z.literal('cancel'),
  automation_job_id: ModelIntegerID
})

export const AutomationJobCLICommand = z.discriminatedUnion('operation', [
  CreateAutomationJobCommand,
  ListAutomationJobsCommand,
  ShowAutomationJobCommand,
  CancelAutomationJobCommand
])

export type AutomationJobCLICommand = z.output<typeof AutomationJobCLICommand>

export type AutomationJobCLIResponse = { ok: true; result: Record<string, unknown> } | { ok: false; error: string }
