import { expect, test } from 'bun:test'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { mkdirAgentSync } from '../../../src/common/agent-user'
import { agentProcessArgv } from '../../../src/core/execution/process-group'
import { runAutomationJob } from '../../../src/automation-jobs/run'
import { runFixture, request, rpcStub } from '../../support/automation-job-run'

if (process.platform !== 'linux' || !existsSync('/etc/ankole-agent-computer-container')) {
  throw new Error('Worker credential tests require the Worker image; run bun run test:integration:docker')
}

test('model processes cannot read or signal the credential-holding Worker and supervisor', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ankole-worker-credentials-'))
  mkdirAgentSync(root, 0o700)
  const agent = `credential-test-${crypto.randomUUID()}`
  const script = join(root, 'worker.ts')
  writeFileSync(script, workerSource(root), { mode: 0o600 })
  const child = Bun.spawn(['/usr/local/bin/ankole-worker-entry', process.execPath, script], {
    env: {
      ...process.env,
      WORKER_ID: agent,
      ANKOLE_WORKER_STORAGE: 'mounted',
      ANKOLE_WORKER_BOOTSTRAP: '',
      ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: 'credential-isolation-fixture'
    },
    stdout: 'pipe',
    stderr: 'pipe'
  })

  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])
    expect(code, stderr).toBe(0)
    expect(JSON.parse(stdout)).toEqual({
      workerUID: 0,
      retainedInitialEnvironment: true,
      command: { uid: 1000, protectedProcesses: 3, bridge: true, files: true },
      codexUID: 1000,
      browserUID: 1000,
      mcp: true
    })
  } finally {
    child.kill()
    rmSync(root, { recursive: true, force: true })
    rmSync(`/agents/${agent}`, { force: true })
  }
}, 30_000)

test('Automation runs as the Agent user and can read its context and use the emit bridge', async () => {
  const fixture = runFixture(`
import { readFileSync } from 'node:fs'
if (process.getuid() !== 1000) throw new Error('Automation retained the Worker uid')
if (!/^NoNewPrivs:\\s+1$/m.test(readFileSync('/proc/self/status', 'utf8'))) throw new Error('missing no-new-privs')
if (process.env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY) throw new Error('Automation inherited the Worker key')
await emitEvent({uid: process.getuid(), value: context().event.data.value})
`)
  mkdirAgentSync(fixture.root, 0o700)
  const emitted: unknown[] = []
  try {
    const result = await runAutomationJob(request(fixture, { value: 42 }), {
      config: fixture.config,
      sdkPath: fixture.sdkPath,
      rpc: rpcStub(fixture, emitted)
    })
    expect(result.status, result.error).toBe('succeeded')
    expect(emitted).toEqual([{ uid: 1000, value: 42 }])
  } finally {
    rmSync(fixture.root, { recursive: true, force: true })
  }
})

test('the entry refuses to run the credential owner as the Agent user', async () => {
  const child = Bun.spawn(agentProcessArgv(['/usr/local/bin/ankole-worker-entry', 'true']), {
    env: { ...process.env, WORKER_ID: 'credential-rejected-agent', ANKOLE_WORKER_STORAGE: 'mounted' },
    stdout: 'ignore',
    stderr: 'pipe'
  })
  expect(await child.exited).toBe(77)
  expect(await new Response(child.stderr).text()).toContain('Worker must start as root')
})

test('the trusted supervisor ends detached Agent writers before it restarts the Worker', async () => {
  const root = mkdtempSync(join(tmpdir(), 'ankole-worker-writers-'))
  mkdirAgentSync(root, 0o700)
  const agent = `writer-test-${crypto.randomUUID()}`
  const script = join(root, 'worker.ts')
  const src = join(import.meta.dir, '../../../src')
  writeFileSync(
    script,
    `
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { agentProcessArgv } from ${JSON.stringify(join(src, 'core/execution/process-group.ts'))}
const root = ${JSON.stringify(root)}
if (!existsSync(root + '/writer.pid')) {
  const child = Bun.spawn(agentProcessArgv(['/bin/sh', '-c', 'while :; do sleep 0.1; done']), {
    env: {PATH: process.env.PATH}, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore', detached: true})
  writeFileSync(root + '/writer.pid', String(child.pid))
  while (!/^Uid:\\s+1000\\s/m.test(readFileSync('/proc/' + child.pid + '/status', 'utf8'))) await Bun.sleep(10)
  process.exit(3)
}
const pid = Number(readFileSync(root + '/writer.pid', 'utf8'))
if (existsSync('/proc/' + pid)) throw new Error('former Agent writer survived the restart')
console.log('restarted without former writers')
`,
    { mode: 0o600 }
  )
  const child = Bun.spawn(['/usr/local/bin/ankole-worker-entry', process.execPath, script], {
    env: { ...process.env, WORKER_ID: agent, ANKOLE_WORKER_STORAGE: 'mounted', ANKOLE_WORKER_BOOTSTRAP: '' },
    stdout: 'pipe',
    stderr: 'pipe'
  })
  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text()
    ])
    expect(code, stderr).toBe(0)
    expect(stdout.trim()).toBe('restarted without former writers')
    expect(stderr).toContain('worker.restart_scheduled')
  } finally {
    child.kill()
    rmSync(root, { recursive: true, force: true })
    rmSync(`/agents/${agent}`, { force: true })
  }
}, 10_000)

const commandProbe = `
import ctypes, errno, json, os, socket, sys
assert os.getuid() == os.geteuid() == os.getgid() == os.getegid() == 1000
assert 'ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY' not in os.environ
status = dict(line.split(':', 1) for line in open('/proc/self/status') if ':' in line)
assert status['NoNewPrivs'].strip() == '1'
assert all(int(status[name].strip(), 16) == 0 for name in ['CapEff', 'CapPrm', 'CapInh', 'CapAmb'])
libc = ctypes.CDLL(None, use_errno=True)
for pid in map(int, sys.argv[1:4]):
    try:
        open(f'/proc/{pid}/environ', 'rb').read()
    except PermissionError:
        pass
    else:
        raise AssertionError(f'credential process {pid} is readable')
    assert libc.ptrace(16, pid, None, None) == -1
    assert ctypes.get_errno() == errno.EPERM
    try:
        os.kill(pid, 0)
    except PermissionError:
        pass
    else:
        raise AssertionError(f'credential process {pid} can be signalled')
try:
    os.setuid(0)
except PermissionError:
    pass
else:
    raise AssertionError('command regained root')
root = os.getcwd()
assert open(root + '/agent-token').read() == 'agent-scoped-fixture'
for operation in [lambda: open(root + '/SOUL.md', 'w'), lambda: os.chmod(root + '/SOUL.md', 0o600)]:
    try:
        operation()
    except PermissionError:
        pass
    else:
        raise AssertionError('command changed a control-plane document')
sock = socket.socket(socket.AF_UNIX)
sock.connect(root + '/bridge.sock')
sock.sendall(b'{}\\n')
assert json.loads(sock.recv(4096)) == {'ok': True}
open(root + '/command-output', 'w').write('ok')
print(json.dumps({'uid': os.getuid(), 'protectedProcesses': 3, 'bridge': True, 'files': True}))
`

function workerSource(root: string): string {
  const src = join(import.meta.dir, '../../../src')
  const server = join(import.meta.dir, '../../fixtures/mcp-stdio-server.ts')
  return `
import { readFileSync } from 'node:fs'
import { mkdirAgentSync } from ${JSON.stringify(join(src, 'common/agent-user.ts'))}
import { writeFileAtomic, writeFileAtomicSync } from ${JSON.stringify(join(src, 'common/atomic-write.ts'))}
import { runWorkspaceProcess } from ${JSON.stringify(join(src, 'tools/computer/commands.ts'))}
import { startSocketLineBridge } from ${JSON.stringify(join(src, 'core/socket-line-bridge.ts'))}
import { materializeCodexConfig } from ${JSON.stringify(join(src, 'core/codex-runner/runtime/agent-home-config.ts'))}
import { codexAppServerSpec } from ${JSON.stringify(join(src, 'core/codex-runner/runtime/app-server-spec.ts'))}
import { CodexAppServerClient } from ${JSON.stringify(join(src, 'core/codex-runner/runtime/app-server-client.ts'))}
import { BrowserDaemonSupervisor } from ${JSON.stringify(join(src, 'browser-runtime/daemon-supervisor.ts'))}
import { materializeMCPorterConfig } from ${JSON.stringify(join(src, 'tools/mcp/mcporter-config.ts'))}

const root = ${JSON.stringify(root)}
delete process.env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY
const retainedInitialEnvironment = readFileSync('/proc/self/environ').includes('credential-isolation-fixture')
await writeFileAtomic(root + '/agent-token', 'agent-scoped-fixture', 0o600)
writeFileAtomicSync(root + '/SOUL.md', 'control-plane document', 0o444)
const bridge = startSocketLineBridge({socketPath: root + '/bridge.sock', maxRequestBytes: 100,
  oversizeError: 'oversize', handleLine: async () => ({ok: true})})
let command
try {
  const result = await runWorkspaceProcess({commandArgv: ['python3', '-c', ${JSON.stringify(commandProbe)},
    String(process.pid), String(process.ppid), '1']}, root, root)
  if (result.exitCode !== 0) throw new Error(result.stderr.toString())
  command = JSON.parse(result.stdout.toString())
} finally { bridge.close() }

process.env.CODEX_SQLITE_HOME = root + '/sqlite'
const codex = new CodexAppServerClient(codexAppServerSpec(materializeCodexConfig({agentHomeRoot: root})))
const codexUID = await agentProcessUID(codex.processID)
await codex.initialize()
await codex.closeAndWait()

let browserPID
const browser = new BrowserDaemonSupervisor({socketPath: root + '/browser/daemon.sock',
  daemonEntry: process.env.ANKOLE_BROWSER_DAEMON_ENTRY,
  onEvent: event => { if (event.kind === 'started') browserPID = event.pid }})
let browserUID
try {
  await browser.start()
  browserUID = await agentProcessUID(browserPID)
} finally { await browser.stop() }

const config = materializeMCPorterConfig([{name: 'fixture', transport: 'stdio', sourceSkills: [],
  command: 'test "$(id -u)" = 1000 && test -z "$ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" && exec bun ' + ${JSON.stringify(server)}}])
try {
  const result = await runWorkspaceProcess({commandArgv: ['mcporter', 'call', 'fixture.stdio_echo', '--json', '-',
    '--output', 'json', '--timeout', '10000'], env: config.env, stdin: '{}'}, root, root)
  if (result.exitCode !== 0 || !result.stdout.includes('stdio response')) throw new Error(result.stderr.toString())
} finally { config.cleanup() }

console.log(JSON.stringify({workerUID: process.getuid(), retainedInitialEnvironment, command, codexUID, browserUID, mcp: true}))

async function agentProcessUID(pid) {
  const deadline = Date.now() + 5000
  while (Date.now() < deadline) {
    const status = readFileSync('/proc/' + pid + '/status', 'utf8')
    const uid = Number(/^Uid:\\s+(\\d+)/m.exec(status)?.[1])
    if (uid === 1000) {
      if (!/^NoNewPrivs:\\s+1$/m.test(status) || !/^CapEff:\\s+0+$/m.test(status)) throw new Error('child kept privileges')
      return uid
    }
    await Bun.sleep(10)
  }
  throw new Error('model process did not drop its uid')
}
`
}
