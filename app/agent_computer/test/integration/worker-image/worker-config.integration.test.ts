import { expect, it } from 'bun:test'
import { loadWorkerConfig } from '../../../src/worker/config'

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
