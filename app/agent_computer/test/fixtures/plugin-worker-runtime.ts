import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { CodexAppServerClient } from '../../src/core/codex-runner/runtime/app-server-client'
import { AgentCodexRuntime } from '../../src/core/codex-runner/runtime/agent-runtime-manager'
import { prepareAgentPlugins } from '../../src/core/codex-runner/runtime/agent-plugin-materializer'
import {
  refreshCodexAgentRuntimeCredential,
  resetCodexAgentRuntimeConfig
} from '../../src/core/codex-runner/runtime/agent-home-config'
import type { ThreadStartResponse } from '../../src/core/codex-runner/generated/protocol/v2/ThreadStartResponse'

const input = JSON.parse(readFileSync(process.argv[2]!, 'utf8')) as {
  root: string
  worker: string
  baseURL: string
  config: Record<string, unknown>
}
const agentHome = join(input.root, 'shared-agent-home')
const codexHome = join(input.root, input.worker, 'codex-home')
const projectRoot = join(agentHome, 'jobs', input.worker)
mkdirSync(codexHome, { recursive: true })
resetCodexAgentRuntimeConfig(codexHome, input.baseURL)
refreshCodexAgentRuntimeCredential(codexHome, 'contract-key')
const prepared = prepareAgentPlugins({
  projectRoot,
  agentPlugins: [],
  codexHome,
  libraryRoot: join(input.root, 'library'),
  initializeProject: true,
  agentsContent: 'Complete the test request.'
})
let terminalStatus: string | undefined
const client = new CodexAppServerClient({
  cwd: agentHome,
  env: {
    PATH: process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin',
    HOME: agentHome,
    CODEX_HOME: codexHome,
    CODEX_UNSAFE_ALLOW_NO_SANDBOX: '1',
    LANG: 'C.UTF-8'
  },
  onNotification(message) {
    if (message.method === 'turn/completed') {
      terminalStatus = (message.params as { turn: { status: string } }).turn.status
    }
  }
})
const timeout = setTimeout(() => {
  throw new Error('Worker plugin runtime timed out')
}, 45_000)
try {
  await client.initialize()
  writeFileSync(join(input.root, `ready-${input.worker}`), '')
  while (!existsSync(join(input.root, 'start'))) await Bun.sleep(10)
  const runtime = new AgentCodexRuntime('same-agent', client)
  await runtime.ensureAgentPlugins(prepared)
  const thread = (await client.request('thread/start', {
    cwd: projectRoot,
    model: 'gpt-5.4',
    modelProvider: 'ankole_aigateway',
    approvalPolicy: 'never',
    sandbox: 'danger-full-access',
    config: input.config
  })) as ThreadStartResponse
  await client.request('turn/start', {
    threadId: thread.thread.id,
    input: [{ type: 'text', text: `Verify Worker ${input.worker}.`, text_elements: [] }],
    cwd: projectRoot,
    approvalPolicy: 'never',
    sandboxPolicy: { type: 'dangerFullAccess' }
  })
  while (terminalStatus === undefined) await Bun.sleep(10)
  if (terminalStatus !== 'completed') throw new Error(`First Turn ended with ${terminalStatus}`)
  process.stdout.write(JSON.stringify({ marketplacePath: prepared.marketplacePath, threadId: thread.thread.id }))
} finally {
  clearTimeout(timeout)
  await client.close()
}
