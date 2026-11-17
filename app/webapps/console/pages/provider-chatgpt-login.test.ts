import { afterEach, describe, expect, it } from 'bun:test'
import { InternalAPIError } from '../../common/internal-api-client'
import { ChatGPTLoginModel } from '../state/chatgpt-login-model'

async function until(condition: () => boolean, timeout = 2000) {
  const deadline = Date.now() + timeout
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('condition timed out')
    await Bun.sleep(5)
  }
}

describe('ChatGPTLoginModel (XState v5)', () => {
  const activeModels: { [Symbol.dispose](): void }[] = []
  afterEach(() => {
    for (const model of activeModels.splice(0)) model[Symbol.dispose]()
  })
  it('stops polling on terminal device errors, preserves metadata, and restarts cleanly without stale poll overwrite', async () => {
    let startCalls = 0
    let pollCalls = 0
    let completed = 0

    const model = new ChatGPTLoginModel({
      async startLogin({ label, priority }) {
        startCalls++
        return {
          mode: 'device',
          status: 'pending',
          user_code: `CODE-${startCalls}`,
          verification_url: 'https://auth.openai.com/device',
          retry_after: 0.02,
          login_context: { attempt: startCalls, label, priority }
        }
      },
      async pollLogin({ loginContext }) {
        pollCalls++
        if (loginContext.attempt === 1) {
          throw new InternalAPIError(400, 'Bad Request', {
            errors: [{ code: 'chatgpt_login_expired', detail: 'Device code expired' }]
          })
        }
        return { status: 'complete' }
      },
      async completeBrowserLogin() {},
      onCompleted: () => {
        completed++
      }
    })
    activeModels.push(model)

    model.open({ providerID: 'openai-chatgpt', label: 'Primary Seat', priority: '3' })
    model.submit()
    await until(() => model.snapshot.value.matches('failed'))

    // Terminal `chatgpt_login_expired` transitions out of deviceFlow into `failed`:
    // polling stops, metadata fields stay intact, and restart button is exposed.
    const pollsAtFailure = pollCalls
    expect(pollsAtFailure).toBe(1)
    expect(model.showingDeviceFlow.value).toBe(false)
    expect(model.showingMetadataFields.value).toBe(true)
    expect(model.isRestart.value).toBe(true)
    expect(model.label.value).toBe('Primary Seat')
    expect(model.priority.value).toBe('3')
    await Bun.sleep(60)
    expect(pollCalls).toBe(pollsAtFailure)

    // Restarting issues a new device code and completes cleanly.
    model.submit()
    await until(() => completed === 1)
    expect(startCalls).toBe(2)
    expect(model.snapshot.value.matches('completed')).toBe(true)
  })

  it('continues polling across retryable 429/unreachable responses and cancels in-flight requests on close', async () => {
    let pollCalls = 0
    const heldStart = Promise.withResolvers<Record<string, unknown>>()
    let aborted = false

    const model = new ChatGPTLoginModel({
      async startLogin({ label, signal }) {
        if (label === 'Slow Start') {
          signal.addEventListener('abort', () => {
            aborted = true
          })
          return heldStart.promise
        }
        return {
          mode: 'device',
          status: 'pending',
          user_code: 'RETRY-1',
          verification_url: 'https://auth.openai.com/device',
          retry_after: 0.015,
          login_context: { session: 's1' }
        }
      },
      async pollLogin() {
        pollCalls++
        if (pollCalls === 1) {
          throw new InternalAPIError(503, 'Service Unavailable', {
            errors: [{ code: 'chatgpt_login_unreachable', detail: 'Gateway timeout' }]
          })
        }
        return { status: 'complete' }
      },
      async completeBrowserLogin() {}
    })
    activeModels.push(model)

    model.open({ providerID: 'openai-chatgpt', label: 'Retry Seat', priority: '1' })
    model.submit()
    await until(() => model.snapshot.value.matches('completed'))
    expect(pollCalls).toBe(2)

    // Closing while `starting` aborts the in-flight request and ignores any late resolution.
    model.open({ providerID: 'openai-chatgpt', label: 'Slow Start', priority: '0' })
    model.submit()
    expect(model.submitting.value).toBe(true)
    model.close()
    expect(aborted).toBe(true)
    heldStart.resolve({
      mode: 'device',
      status: 'pending',
      user_code: 'LATE',
      login_context: { session: 'late' }
    })
    await Bun.sleep(20)
    expect(model.snapshot.value.matches('closed')).toBe(true)
    expect(model.login.value).toBeUndefined()
  })
})
