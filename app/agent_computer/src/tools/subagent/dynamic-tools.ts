import type { JsonObject } from '@pleisto/active-support'
import { estimateO200kBaseTokens } from '@ankole/kernel'
import { errorMessage } from '../../common/errors'
import { truncateUtf8Safe, utf8ByteLength } from '../../common/text-sanitize'
import type { AgentTool } from '../../core'
import { zodToJSONSchema } from '../../core/llm/tool-schema'
import { skillPromptEntryFromRuntime } from '../../prompts/system_prompt'
import { formatSkillsForSystemPrompt } from '../../prompts/skills_prompt'
import type { SkillPromptEntry } from '../../prompts/skills_prompt'
import type { RuntimeSkillSummary } from '../../lanes/rpc_lane'
import type { DynamicToolCallParams } from './generated/protocol/v2/DynamicToolCallParams'
import type { DynamicToolCallResponse } from './generated/protocol/v2/DynamicToolCallResponse'
import type { DynamicToolSpec } from './generated/protocol/v2/DynamicToolSpec'
import type { JsonValue } from './generated/protocol/serde_json/JsonValue'

const maxToolResultBytes = 16_384
const truncationSuffix = '...[truncated]'
const allowedToolNames = new Set(['skill_view', 'web_search', 'memory_search', 'memory_browse'])
const maxDeveloperInstructionTokens = 24_000
const truncationMarker = '\n\n[truncated to the subagent context budget]'

export type SubagentProjection = {
  developerInstructions: string
  dynamicTools: DynamicToolSpec[]
  quarantinedTools: string[]
  projectedSkillCount: number
  handleToolCall(params: DynamicToolCallParams, signal: AbortSignal): Promise<DynamicToolCallResponse>
}

export function buildSubagentProjection(input: {
  tools: AgentTool[]
  skills: RuntimeSkillSummary[]
  soul: string
  mission: string
  onAudit?: (eventType: string, payload: JsonObject) => void
}): SubagentProjection {
  const skillEntries = input.skills.map(skillPromptEntryFromRuntime).filter(isSkillPromptEntry)
  const tools = new Map<string, AgentTool>()
  const dynamicTools: DynamicToolSpec[] = []
  const quarantinedTools: string[] = []

  for (const tool of input.tools) {
    if (!allowedToolNames.has(tool.name)) continue
    try {
      const inputSchema = zodToJSONSchema(tool.schema)
      dynamicTools.push({
        type: 'function',
        name: tool.name,
        description: tool.description,
        inputSchema: inputSchema as unknown as JsonValue
      })
      tools.set(tool.name, tool)
    } catch (error) {
      quarantinedTools.push(tool.name)
      input.onAudit?.('dynamic_tool_quarantined', { tool: tool.name, error: errorMessage(error) })
    }
  }

  return {
    developerInstructions: developerInstructions(input, skillEntries),
    dynamicTools,
    quarantinedTools,
    projectedSkillCount: skillEntries.filter(skill => !skill.disableModelInvocation).length,
    async handleToolCall(params, signal) {
      const tool = tools.get(params.tool)
      if (!tool) {
        return dynamicToolFailure(`Dynamic tool is unavailable: ${params.tool}`)
      }

      const parsed = tool.schema.safeParse(params.arguments)
      if (!parsed.success) {
        input.onAudit?.('dynamic_tool_invalid_arguments', {
          tool: params.tool,
          call_id: params.callId,
          issues: parsed.error.issues as unknown as JsonObject
        })
        return dynamicToolFailure(`Invalid arguments for ${params.tool}: ${parsed.error.message}`)
      }

      input.onAudit?.('dynamic_tool_started', { tool: params.tool, call_id: params.callId })
      try {
        const result = await tool.execute(params.callId, parsed.data, signal)
        const text = boundedText(toolResultText(result))
        input.onAudit?.('dynamic_tool_completed', { tool: params.tool, call_id: params.callId, success: true })
        return { contentItems: [{ type: 'inputText', text }], success: true }
      } catch (error) {
        const message = boundedText(errorMessage(error))
        input.onAudit?.('dynamic_tool_completed', {
          tool: params.tool,
          call_id: params.callId,
          success: false,
          error: message
        })
        return dynamicToolFailure(message)
      }
    }
  }
}

function developerInstructions(input: { soul: string; mission: string }, skillEntries: SkillPromptEntry[]): string {
  const contractSections = [
    '---',
    'You are a subagent delegated by the Ankole agent above. Work autonomously on the delegated brief. Your final message is the delegation report the parent agent will review — include what you did, evidence, artifact paths, and remaining risks.',
    'Background task safety: your turn ends the moment your top-level answer ends; never background-and-yield, never end while a shell job you still need is running. Do all waiting in the foreground.',
    'User-visible replies, attachments, scheduling, clarification, and long-term memory writes belong to the parent agent. Put deliverables under the working directory you were given.',
    'Ankole projects only the following parent-owned read capabilities into this Codex thread: skill_view, web_search, memory_search, and memory_browse. No terminal, browser, scheduling, attachment, clarification, memory-write, skill-write, or nested-subagent tool is available through this bridge.'
  ]
  const contract = contractSections.join('\n\n')
  const contractTokens = estimateO200kBaseTokens(contract)
  const identityBudget = Math.max(Math.floor((maxDeveloperInstructionTokens - contractTokens) / 3), 0)
  const soul = fitTextToTokenBudget(input.soul.trim(), identityBudget)
  const mission = fitTextToTokenBudget(input.mission.trim(), identityBudget)
  const identityAndContract = [soul, mission, contract].filter(Boolean).join('\n\n')
  const skillsBudget = Math.max(maxDeveloperInstructionTokens - estimateO200kBaseTokens(identityAndContract) - 32, 0)
  const skillsIndex = fitSkillsToTokenBudget(skillEntries, skillsBudget)

  return [soul, mission, contractSections.slice(0, -1).join('\n\n'), skillsIndex, contractSections.at(-1)]
    .filter(Boolean)
    .join('\n\n')
}

function fitSkillsToTokenBudget(entries: SkillPromptEntry[], maxTokens: number): string {
  if (entries.length === 0 || maxTokens <= 0) return ''

  let low = 0
  let high = entries.length
  let best = ''

  while (low <= high) {
    const midpoint = Math.floor((low + high) / 2)
    const candidate = formatSkillsForSystemPrompt(entries.slice(0, midpoint))
    if (estimateO200kBaseTokens(candidate) <= maxTokens) {
      best = candidate
      low = midpoint + 1
    } else {
      high = midpoint - 1
    }
  }

  if (best && high < entries.length) {
    const marker = `\n# Skills index truncated by token budget; use memory tools when the brief needs additional context.`
    if (estimateO200kBaseTokens(best + marker) <= maxTokens) return best + marker
  }
  return best
}

function fitTextToTokenBudget(text: string, maxTokens: number): string {
  if (!text || maxTokens <= 0) return ''
  if (estimateO200kBaseTokens(text) <= maxTokens) return text

  const chars = Array.from(text)
  let low = 0
  let high = chars.length
  let best = ''

  while (low <= high) {
    const midpoint = Math.floor((low + high) / 2)
    const candidate = chars.slice(0, midpoint).join('') + truncationMarker
    if (estimateO200kBaseTokens(candidate) <= maxTokens) {
      best = candidate
      low = midpoint + 1
    } else {
      high = midpoint - 1
    }
  }

  return best
}

function isSkillPromptEntry(entry: SkillPromptEntry | null): entry is SkillPromptEntry {
  return entry !== null
}

function toolResultText(result: { content: unknown[]; details: unknown }): string {
  const text = result.content
    .map(part => {
      if (!part || typeof part !== 'object') return undefined
      const value = part as { type?: unknown; text?: unknown }
      return value.type === 'text' && typeof value.text === 'string' ? value.text : undefined
    })
    .filter((value): value is string => Boolean(value))
    .join('\n')

  if (text) return text
  try {
    return JSON.stringify(result.details)
  } catch {
    return String(result.details)
  }
}

function boundedText(text: string): string {
  if (utf8ByteLength(text) <= maxToolResultBytes) return text
  const prefix = truncateUtf8Safe(text, maxToolResultBytes - utf8ByteLength(truncationSuffix))
  return `${prefix}${truncationSuffix}`
}

function dynamicToolFailure(text: string): DynamicToolCallResponse {
  return { contentItems: [{ type: 'inputText', text: boundedText(text) }], success: false }
}
