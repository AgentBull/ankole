import { expect, it } from 'bun:test'
import { loadWorkerConfig } from '../../../src/worker/config'
import { agentProcessArgv } from '../../../src/core/execution/process-group'
import { mkdirAgent } from '../../../src/common/agent-user'

it('loads the image configuration and removes the auth key before child processes start', () => {
  const env = {
    ...process.env,
    ANKOLE_RUNTIME_FABRIC_ENDPOINT: 'ws://127.0.0.1:4000/runtime-fabric/worker',
    ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: ' secret with / symbols ',
    WORKER_ID: 'worker-a'
  }

  const config = loadWorkerConfig(env)

  expect(config.workerAuthKey).toBe(' secret with / symbols ')
  expect(env.ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY).toBeUndefined()
  expect(config.browser).toEqual({
    daemonEntry: process.env.ANKOLE_BROWSER_DAEMON_ENTRY!,
    runnerPath: process.env.ANKOLE_BROWSER_RUNNER!,
    localChromiumExecutable: process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE!
  })
})

it('installs the Pod CLI with the editor codec and real applet build dependencies', async () => {
  const { mkdtemp, rm } = await import('node:fs/promises')
  const root = await mkdtemp('/tmp/ankole-pod-image-')
  const directory = `${root}/tracker`
  try {
    const help = Bun.spawnSync(['ankole-pod', '--help'])
    expect(help.exitCode).toBe(0)
    expect(help.stdout.toString()).toContain('pages.write')
    expect(Bun.spawnSync(['ankole-pod', 'applet', 'init', directory]).exitCode).toBe(0)
    const build = Bun.spawnSync(['ankole-pod', 'applet', 'build', directory])
    expect(build.stderr.toString()).toBe('')
    expect(build.exitCode).toBe(0)
    const script = await Bun.file(`${directory}/dist/main.js`).text()
    expect(script).toContain('@ankole/applet-sdk')
    expect(script).not.toContain('jsxDEV')
    expect(await Bun.file(`${directory}/dist/index.html`).text()).toContain('./main.js')
    const { parseMarkdown, printXml } = await import('@ankole/block-editor/document')
    expect(printXml(parseMarkdown('## Saved report'))).toContain('Saved report')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

it.skipIf(process.arch !== 'x64')('provides OSSFS2 for Function Compute custom images', () => {
  const result = Bun.spawnSync(['ossfs2', '--version'])
  expect(result.exitCode).toBe(0)
  expect(result.stdout.toString()).toContain('2.0.10')
  expect(Bun.spawnSync(['fusermount3', '--version']).exitCode).toBe(0)
})

it('the per-Agent Python bootstrap inherits the image packages without a download', async () => {
  const { mkdtemp, rm, writeFile, readFile } = await import('node:fs/promises')
  const root = await mkdtemp('/tmp/ankole-python-image-')
  await mkdirAgent(root, 0o700)
  const environment = `${root}/python`
  try {
    for (let attempt = 0; attempt < 2; attempt++) {
      const result = Bun.spawnSync(
        agentProcessArgv(['bash', '/repo/app/library/skills/jupyter-live-kernel/scripts/ensure_python_env.sh']),
        { env: { ...process.env, ANKOLE_AGENT_PYTHON_ENV: environment, UV_OFFLINE: '1' } }
      )
      expect(result.stderr.toString()).not.toContain('missing packages')
      expect(result.exitCode, result.stderr.toString()).toBe(0)
      const probe = Bun.spawnSync(
        agentProcessArgv([
          `${environment}/bin/python`,
          '-c',
          'import sys, jupyterlab, ipykernel, websocket, jupyter_client, jupyter_server, nbformat; print(sys.prefix)'
        ])
      )
      expect(probe.exitCode, probe.stderr.toString()).toBe(0)
      expect(probe.stdout.toString().trim()).toBe(environment)
      if (attempt === 0) await writeFile(`${environment}/keep.txt`, 'Keep Agent data')
    }
    expect(await readFile(`${environment}/keep.txt`, 'utf8')).toBe('Keep Agent data')
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
