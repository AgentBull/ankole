import { z } from 'zod'
import type { AgentTool } from '../../core'
import { modelIntegerIDFromWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type AgentPluginCatalogEntry, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'

const identifier = /^[a-z][a-z0-9_-]{0,63}$/

const BackgroundAgentJobStatusSchema = z.enum([
  'queued',
  'running',
  'waiting_on_user',
  'succeeded',
  'failed',
  'stopped'
])

type CreateBackgroundJobResult = {
  job_id: number
  status: z.output<typeof BackgroundAgentJobStatusSchema>
}

export type CreateBackgroundJobToolOptions = {
  turnStart: TurnStart
  agentPluginCatalog: AgentPluginCatalogEntry[]
  rpc: RPCRequester
}

export function createCreateBackgroundJobTool(
  opts: CreateBackgroundJobToolOptions
): AgentTool<ReturnType<typeof createBackgroundJobParamsSchema>, CreateBackgroundJobResult> {
  const workspaceTemplates = availableWorkspaceTemplates(opts.agentPluginCatalog)

  return {
    name: 'create_background_job',
    description: [
      'Create durable background work and return immediately.',
      'title is only a management label and is not sent to Codex.',
      'task is sent verbatim as the first Codex user prompt, so it must contain the complete requirements and acceptance criteria.',
      'The Job automatically receives every current enabled Skill that permits Background Agent Jobs.',
      workspaceTemplateDescription(workspaceTemplates)
    ].join(' '),
    schema: createBackgroundJobParamsSchema(workspaceTemplates),
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => 'create background agent job',
    async execute(toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.create'> = {
        sourceToolCallId: toolCallID,
        title: params.title.trim(),
        task: params.task,
        workspaceTemplateId: params.workspace_template_id ?? ''
      }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobCreate, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        job_id: modelIntegerIDFromWire(response.jobId, 'background Agent Job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  }
}

type WorkspaceTemplate = {
  id: string
  description: string
}

function createBackgroundJobParamsSchema(workspaceTemplates: WorkspaceTemplate[]) {
  return z
    .object({
      title: z
        .string()
        .min(1)
        .max(200)
        .refine(value => value.trim().length > 0, 'title must not be blank'),
      task: z
        .string()
        .min(1)
        .refine(value => value.trim().length > 0, 'task must not be blank'),
      workspace_template_id: workspaceTemplateSchema(workspaceTemplates).optional()
    })
    .strict()
}

function availableWorkspaceTemplates(catalog: AgentPluginCatalogEntry[]): WorkspaceTemplate[] {
  const templates = catalog
    .filter(entry => entry.hasWorkspaceTemplate)
    .map(entry => ({ id: entry.id, description: entry.description }))
    .sort((left, right) => compareCodePoints(left.id, right.id))

  for (const template of templates) {
    if (!identifier.test(template.id)) throw new Error(`invalid workspace template id: ${template.id}`)
  }
  if (new Set(templates.map(template => template.id)).size !== templates.length) {
    throw new Error('duplicate workspace template id')
  }

  return templates
}

function workspaceTemplateSchema(workspaceTemplates: WorkspaceTemplate[]): z.ZodType<string> {
  const ids = workspaceTemplates.map(template => template.id)
  if (ids.length === 0) {
    return z.string().refine(() => false, { message: 'no workspace templates are available' })
  }
  return z.enum(ids as [string, ...string[]])
}

function workspaceTemplateDescription(workspaceTemplates: WorkspaceTemplate[]): string {
  if (workspaceTemplates.length === 0) return 'No workspace template is available; omit workspace_template_id.'
  return `Available workspace templates: ${workspaceTemplates
    .map(template => `${template.id} (${template.description})`)
    .join(', ')}. Omit workspace_template_id to use no template.`
}

function compareCodePoints(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0
}
