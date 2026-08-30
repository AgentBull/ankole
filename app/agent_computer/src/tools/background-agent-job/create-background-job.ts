import { compareCodePointStrings } from '../../common/ordering'
import { z } from 'zod'
import { sanitizeCatalogLine } from '../../common/text-sanitize'
import { defineWorkerTool, type WorkerAgentTool } from '../../core'
import {
  availableCustomModelProfiles,
  customModelProfileDescription,
  customModelProfileSchema,
  type CustomModelProfile
} from '../../core/custom-model-profiles'
import { modelIntegerIDFromWire } from '../../core/model-integer-id'
import { jsonToolResult } from '../../core/tool-result'
import type { TurnStart } from '../../lanes/actor_lane'
import { rpcMethods, type AgentPluginCatalogEntry, type RPCRequester, type RPCRequestInit } from '../../lanes/rpc_lane'
import {
  BackgroundAgentJobStatusSchema,
  type BackgroundAgentJobStatus
} from '../../core/background-agent-job-documents'

const identifier = /^[a-z][a-z0-9_-]{0,63}$/
const CATALOG_DESCRIPTION_MAX_CHARS = 400

type CreateBackgroundJobResult = {
  job_id: number
  status: BackgroundAgentJobStatus
}

export type CreateBackgroundJobToolOptions = {
  turnStart: TurnStart
  agentPluginCatalog: AgentPluginCatalogEntry[]
  rpc: RPCRequester
}

export function createCreateBackgroundJobTool(
  opts: CreateBackgroundJobToolOptions
): WorkerAgentTool<ReturnType<typeof createBackgroundJobParamsSchema>, CreateBackgroundJobResult> {
  const workspaceTemplates = availableWorkspaceTemplates(opts.agentPluginCatalog)
  const customModelProfiles = availableCustomModelProfiles(opts.turnStart)

  return defineWorkerTool({
    name: 'create_background_job',
    description: [
      'Delegate a durable job to a background agent.',
      'title is only a management label and is not sent to Codex.',
      'task is the work handed off to the background agent to complete.',
      'State in task what the finished deliverable is and what it must satisfy; the background agent verifies against that before finishing.',
      customModelProfileDescription(customModelProfiles, 'coding'),
      workspaceTemplateDescription(workspaceTemplates)
    ].join(' '),
    schema: createBackgroundJobParamsSchema(workspaceTemplates, customModelProfiles),
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.background_job_create' }),
    async execute(toolCallID, params) {
      const request: RPCRequestInit<'background_agent_job.create'> = {
        sourceToolCallId: toolCallID,
        title: params.title.trim(),
        task: params.task,
        modelProfile: selectedModelProfile(params),
        workspaceTemplateId: params.workspace_template_id ?? ''
      }
      const response = await opts.rpc(rpcMethods.backgroundAgentJobCreate, request, { turn: opts.turnStart.turn })

      return jsonToolResult({
        job_id: modelIntegerIDFromWire(response.jobId, 'background agent job id'),
        status: BackgroundAgentJobStatusSchema.parse(response.status)
      })
    }
  })
}

type WorkspaceTemplate = {
  id: string
  description: string
}

type CreateBackgroundJobParams = {
  title: string
  task: string
  workspace_template_id?: string
  model_profile?: string
}

function selectedModelProfile(params: CreateBackgroundJobParams): string {
  return params.model_profile ?? ''
}

function createBackgroundJobParamsSchema(
  workspaceTemplates: WorkspaceTemplate[],
  customModelProfiles: CustomModelProfile[]
): z.ZodType<CreateBackgroundJobParams> {
  const base = z
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

  if (customModelProfiles.length === 0) return base
  return base.extend({ model_profile: customModelProfileSchema(customModelProfiles).optional() }).strict()
}

function availableWorkspaceTemplates(catalog: AgentPluginCatalogEntry[]): WorkspaceTemplate[] {
  // Template descriptions come from installed plugin packages and are injected
  // into the tool description, so the host re-normalizes them; ids are already
  // held to the strict identifier grammar below.
  const templates = catalog
    .filter(entry => entry.hasWorkspaceTemplate)
    .map(entry => ({
      id: entry.id,
      description: sanitizeCatalogLine(entry.description, CATALOG_DESCRIPTION_MAX_CHARS)
    }))
    .sort((left, right) => compareCodePointStrings(left.id, right.id))

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
