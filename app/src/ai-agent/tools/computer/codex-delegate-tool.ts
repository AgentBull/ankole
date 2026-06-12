import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'
import { materializeRuntimeCredential } from '@/runtime-credentials/service'
import { CODEX_AUTH_PATH, CODEX_CONFIG_PATH, CODEX_HOME } from './runtime-credential-materialization'

const CODEX_RUNS_DIR = 'temp/codex-runs'

const CodexDelegateParams = z.object({
  prompt: z.string().min(1).describe('Complete task prompt for the delegated Codex run.'),
  workdir: z
    .string()
    .optional()
    .describe('Computer workdir for Codex. Defaults to /workspace. Must stay under /workspace.'),
  wait: z.boolean().optional().describe('Wait for completion. Default true. false starts a background command.'),
  timeoutSeconds: z.number().int().min(1).optional().describe('Max seconds for wait=true. Default 1800.'),
  model: z.string().optional().describe('Optional Codex model override.'),
  sandbox: z
    .enum(['read-only', 'workspace-write', 'danger-full-access'])
    .optional()
    .describe('Codex sandbox mode when bypassApprovals is false. Default danger-full-access.'),
  bypassApprovals: z
    .boolean()
    .optional()
    .describe(
      'Use Codex --dangerously-bypass-approvals-and-sandbox. Default true because BullX Computer is the boundary.'
    ),
  skipGitRepoCheck: z.boolean().optional().describe('Pass --skip-git-repo-check to Codex. Default false.')
})

interface CodexDelegateDetails {
  runId: string
  status: 'missing_auth' | 'started' | 'completed' | 'failed'
  sessionId?: string
  exitCode?: number
  errorMessage?: string
  lastMessagePath: string
  lastMessage?: string | null
  credentialMaterialized: boolean
  configMaterialized: boolean
}

export function createCodexDelegateTool(
  context: ComputerToolContext
): AgentTool<typeof CodexDelegateParams, CodexDelegateDetails> {
  return buildTool({
    name: 'codex_delegate',
    label: 'Codex Delegate',
    description:
      'Start a bounded Codex sub-agent run inside this agent computer. Use it when you can define the goal but want another agent loop to plan, inspect files, write and run commands or scripts, validate results, and return a concise answer or artifact. Use wait=false for slow or parallel work, then monitor with the process tool. Give Codex a complete task prompt with relevant context, paths, constraints, success criteria, and output location.',
    schema: CodexDelegateParams,
    executionMode: 'sequential',
    isDestructive: true,
    async execute(_toolCallId, params, signal): Promise<AgentToolResult<CodexDelegateDetails>> {
      const computer = await context.getComputer(signal)
      const runId = genUUIDv7()
      const promptPath = `${CODEX_RUNS_DIR}/${runId}/prompt.txt`
      const lastMessagePath = `${CODEX_RUNS_DIR}/${runId}/last-message.md`
      const absolutePromptPath = `/workspace/${promptPath}`
      const absoluteLastMessagePath = `/workspace/${lastMessagePath}`
      const workdir = normalizeWorkdir(params.workdir)

      const credential = await materializeRuntimeCredential({
        computer,
        agentUid: context.agentUid,
        consumerKind: 'skill',
        consumerName: 'codex',
        credentialName: 'auth_json',
        path: CODEX_AUTH_PATH
      })
      if (!credential) {
        return {
          content: [
            {
              type: 'text',
              text: 'Codex auth is not configured. Store a runtime credential for skill/codex/auth_json at default or agent scope before using codex_delegate.'
            }
          ],
          details: {
            runId,
            status: 'missing_auth',
            errorMessage: 'Codex auth is not configured for skill/codex/auth_json.',
            lastMessagePath: absoluteLastMessagePath,
            lastMessage: null,
            credentialMaterialized: false,
            configMaterialized: false
          }
        }
      }
      const codexConfig = await materializeRuntimeCredential({
        computer,
        agentUid: context.agentUid,
        consumerKind: 'skill',
        consumerName: 'codex',
        credentialName: 'config_toml',
        path: CODEX_CONFIG_PATH
      })

      await computer.writeFiles([{ path: promptPath, content: params.prompt, mode: 0o600 }], { signal })
      const command = buildCodexCommand({
        promptPath: absolutePromptPath,
        lastMessagePath: absoluteLastMessagePath,
        workdir,
        model: params.model,
        sandbox: params.sandbox ?? 'danger-full-access',
        bypassApprovals: params.bypassApprovals ?? true,
        skipGitRepoCheck: params.skipGitRepoCheck ?? false
      })

      if (params.wait === false) {
        const started = await computer.runCommand({
          cmd: 'bash',
          args: ['-lc', command],
          cwd: '/workspace',
          detached: true,
          env: { CODEX_HOME },
          timeoutMs: (params.timeoutSeconds ?? 1800) * 1000,
          signal
        })
        context.backgroundIds.add(started.cmdId)
        return {
          content: [
            {
              type: 'text',
              text: `Codex delegate started. run_id=${runId} session_id=${started.cmdId} last_message=${absoluteLastMessagePath}`
            }
          ],
          details: {
            runId,
            status: 'started',
            sessionId: started.cmdId,
            lastMessagePath: absoluteLastMessagePath,
            lastMessage: null,
            credentialMaterialized: true,
            configMaterialized: Boolean(codexConfig)
          }
        }
      }

      const result = await computer.runCommand({
        cmd: 'bash',
        args: ['-lc', command],
        cwd: '/workspace',
        env: { CODEX_HOME },
        timeoutMs: (params.timeoutSeconds ?? 1800) * 1000,
        signal
      })
      const output = truncateOutput(await result.output('both', { signal }))
      const lastMessage = await readLastMessage(computer, lastMessagePath, signal)
      const status = result.exitCode === 0 ? 'completed' : 'failed'
      return {
        content: [
          {
            type: 'text',
            text: [
              `run_id=${runId}`,
              `status=${status}`,
              `exit_code=${result.exitCode}`,
              `last_message=${absoluteLastMessagePath}`,
              lastMessage ? `\n<codex_last_message>\n${lastMessage}\n</codex_last_message>` : '',
              output ? `\n<codex_log_tail>\n${output}\n</codex_log_tail>` : ''
            ].join('\n')
          }
        ],
        details: {
          runId,
          status,
          exitCode: result.exitCode,
          errorMessage: status === 'failed' ? `Codex exited with code ${result.exitCode}.` : undefined,
          lastMessagePath: absoluteLastMessagePath,
          lastMessage,
          credentialMaterialized: true,
          configMaterialized: Boolean(codexConfig)
        }
      }
    }
  })
}

function buildCodexCommand(input: {
  promptPath: string
  lastMessagePath: string
  workdir: string
  model?: string
  sandbox: 'read-only' | 'workspace-write' | 'danger-full-access'
  bypassApprovals: boolean
  skipGitRepoCheck: boolean
}): string {
  const args = ['codex', 'exec', '--json', '--cd', input.workdir, '--output-last-message', input.lastMessagePath]
  if (input.model?.trim()) args.push('--model', input.model.trim())
  if (input.skipGitRepoCheck) args.push('--skip-git-repo-check')
  if (input.bypassApprovals) args.push('--dangerously-bypass-approvals-and-sandbox')
  else args.push('--sandbox', input.sandbox)
  args.push('-')
  return `${args.map(shellQuote).join(' ')} < ${shellQuote(input.promptPath)}`
}

function normalizeWorkdir(value: string | undefined): string {
  const raw = (value?.trim() || '/workspace').replace(/\\/g, '/').replace(/\/+/g, '/')
  const absolute = raw.startsWith('/') ? raw : `/workspace/${raw}`
  if (absolute !== '/workspace' && !absolute.startsWith('/workspace/')) {
    throw new Error('codex workdir must stay under /workspace')
  }
  if (absolute.split('/').some(part => part === '..')) throw new Error('codex workdir cannot contain ..')
  return absolute
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

async function readLastMessage(
  computer: Pick<Awaited<ReturnType<ComputerToolContext['getComputer']>>, 'readFileToBuffer'>,
  path: string,
  signal?: AbortSignal
): Promise<string | null> {
  const buffer = await computer.readFileToBuffer({ path }, { signal })
  return buffer ? buffer.toString('utf-8') : null
}
