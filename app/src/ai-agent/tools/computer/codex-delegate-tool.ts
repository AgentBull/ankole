import { genUUIDv7 } from '@agentbull/bullx-native-addons'
import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import { buildTool } from '../build-tool'
import type { ComputerToolContext } from './context'
import { truncateOutput } from './format'
import { materializeRuntimeCredential } from '@/runtime-credentials/service'
import { CODEX_AUTH_PATH, CODEX_CONFIG_PATH, CODEX_HOME } from './runtime-credential-materialization'

// Per-run scratch area for delegated Codex runs: the prompt is written here and the run's final
// message is read back from here. Under `temp/` so it shares the throwaway run state, not the
// durable workspace.
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

/**
 * Delegates a self-contained coding subtask to a nested Codex agent running inside this same
 * computer.
 *
 * This is a delegation boundary: BullX defines the goal and hands Codex its own plan/edit/run/verify
 * loop, then collects a single concise result. The contract is one-shot and stateless from BullX's
 * side — the prompt must carry all context, constraints, success criteria, and where to put output,
 * because BullX does not converse with Codex turn by turn. Codex runs with sandbox/approvals
 * bypassed by default precisely because the BullX Computer is already the isolation boundary;
 * re-sandboxing inside it would only get in the model's way (the param can still tighten it).
 * `wait=false` starts it detached and tracked by the `process` tool for slow or parallel work.
 */
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
      // One uuid namespaces this run's prompt and last-message files, so parallel delegations (each
      // its own run) never collide on disk. Both relative and absolute forms are kept because
      // `writeFiles`/`readFileToBuffer` take workspace-relative paths while the Codex CLI flags need
      // absolute ones.
      const runId = genUUIDv7()
      const promptPath = `${CODEX_RUNS_DIR}/${runId}/prompt.txt`
      const lastMessagePath = `${CODEX_RUNS_DIR}/${runId}/last-message.md`
      const absolutePromptPath = `/workspace/${promptPath}`
      const absoluteLastMessagePath = `/workspace/${lastMessagePath}`
      const workdir = normalizeWorkdir(params.workdir)

      // Materialize Codex's auth just in time for this run. The shared session-level materialization
      // already wrote it, but re-resolving here means the tool also works when invoked outside that
      // path and lets it fail fast with an actionable message if no credential is configured.
      const credential = await materializeRuntimeCredential({
        computer,
        agentUid: context.agentUid,
        consumerKind: 'skill',
        consumerName: 'codex',
        credentialName: 'auth_json',
        path: CODEX_AUTH_PATH
      })
      // No auth means Codex cannot run at all, so stop here and tell the model exactly what to
      // configure rather than launching a command that would fail opaquely deep inside Codex.
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
      // Config is optional — a run is fine on Codex defaults — so its absence is not fatal; the
      // result just records whether it was materialized.
      const codexConfig = await materializeRuntimeCredential({
        computer,
        agentUid: context.agentUid,
        consumerKind: 'skill',
        consumerName: 'codex',
        credentialName: 'config_toml',
        path: CODEX_CONFIG_PATH
      })

      // The prompt is passed via a file (read on Codex's stdin), not as a CLI argument. That keeps
      // arbitrarily large prompts off the command line and out of any process listing, and the
      // 0o600 mode keeps it owner-only like the credentials.
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

      // Background path: start Codex detached and hand the model a session id plus the path where
      // its final message will appear, instead of blocking. `CODEX_HOME` points Codex at the
      // just-materialized auth/config. Registering the id lets the `process` tool track it like any
      // other background job.
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

      // Foreground path: block until Codex exits. Its final answer is read from the
      // `--output-last-message` file (the clean result), while the raw log tail is also returned and
      // truncated for context budget so the model can see what happened on failure.
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

/**
 * Assembles the `codex exec` command line. `exec` is the non-interactive mode; `--json` gives a
 * machine-readable log and `--output-last-message` writes Codex's final answer to a file we read
 * back. `bypassApprovals` and `--sandbox` are mutually exclusive — bypass means "no internal
 * sandbox" (the default, since the computer is already the boundary), otherwise the chosen sandbox
 * mode is applied. The trailing `-` plus stdin redirect feeds the prompt file in as the task. Every
 * argument is single-quoted so a prompt path or model name can never break out of the command.
 */
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

/**
 * Resolves the requested workdir to an absolute path and confines it to `/workspace`.
 *
 * Backslashes are folded to forward slashes and repeated slashes collapsed so the prefix check
 * cannot be fooled by `\` or `//`, and any path still containing a `..` segment is rejected outright
 * rather than resolved — together these stop the delegated agent from being pointed at files outside
 * the workspace. A relative input is anchored under `/workspace`.
 */
function normalizeWorkdir(value: string | undefined): string {
  const raw = (value?.trim() || '/workspace').replace(/\\/g, '/').replace(/\/+/g, '/')
  const absolute = raw.startsWith('/') ? raw : `/workspace/${raw}`
  if (absolute !== '/workspace' && !absolute.startsWith('/workspace/')) {
    throw new Error('codex workdir must stay under /workspace')
  }
  if (absolute.split('/').some(part => part === '..')) throw new Error('codex workdir cannot contain ..')
  return absolute
}

/** Wraps a value in single quotes for `bash -lc`, escaping embedded quotes, so model-supplied
 * paths and names cannot inject extra shell words. */
function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

/**
 * Reads Codex's final-answer file, returning null when it is absent. A run can exit without writing
 * one (e.g. it failed early), so the caller treats null as "no clean answer" and falls back to the
 * log tail rather than erroring. Typed to just `readFileToBuffer` so tests can pass a stub.
 */
async function readLastMessage(
  computer: Pick<Awaited<ReturnType<ComputerToolContext['getComputer']>>, 'readFileToBuffer'>,
  path: string,
  signal?: AbortSignal
): Promise<string | null> {
  const buffer = await computer.readFileToBuffer({ path }, { signal })
  return buffer ? buffer.toString('utf-8') : null
}
