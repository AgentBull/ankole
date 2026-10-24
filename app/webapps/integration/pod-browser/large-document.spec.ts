import { state } from './fixtures'
import { expect, test } from '@playwright/test'

test('a valid large Chinese document crosses the real OT socket and reads back unchanged', async ({ browser }) => {
  const context = await browser.newContext()
  await context.addCookies(state.owner.cookies)
  const page = await context.newPage()
  try {
    await page.goto(`${state.base_url}/`)
    const result = await page.evaluate(async owner => {
      const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content
      const headers = {
        accept: 'application/vnd.api+json',
        'content-type': 'application/vnd.api+json',
        'x-ankole-authentication': meta('ankole-authentication')!,
        'x-ankole-pod': meta('ankole-pod')!,
        'x-csrf-token': meta('csrf-token')!
      }
      const request = async (path: string, method = 'GET', body?: unknown) => {
        const options: RequestInit = { method, headers }
        if (body !== undefined) options.body = JSON.stringify({ data: body })
        const response = await fetch(`/api/v2/pod${path}`, options)
        if (!response.ok) throw new Error(`Pod ${path}: ${response.status}`)
        return response.json()
      }
      const { page: documentPage } = await request('/pages', 'POST', {
        type: 'doc',
        title: 'Large Chinese OT document',
        private_owner_uid: owner
      })
      const { token } = await request('/realtime-token')
      const text = '界'.repeat(6_000_000)
      const started = performance.now()
      const payload = JSON.stringify([
        '1',
        '2',
        `page:${documentPage.id}`,
        'changes',
        {
          base_revision: 0,
          client_id: 'large-chinese',
          client_seq: 1,
          changes: [[1, [{ remove: 'PagePlaceholder', value: null }]], [0, [{ type: 'Text', param: text }]], 1]
        }
      ])
      const revision = await new Promise<number>((resolve, reject) => {
        const url = new URL('/pod/socket/websocket', location.href)
        url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
        url.search = new URLSearchParams({ token, vsn: '2.0.0' }).toString()
        const socket = new WebSocket(url)
        let settled = false
        const timer = setTimeout(() => {
          settled = true
          socket.close()
          reject(new Error('Large OT write timed out'))
        }, 90_000)
        socket.onopen = () => socket.send(JSON.stringify(['1', '1', `page:${documentPage.id}`, 'phx_join', {}]))
        socket.onmessage = event => {
          const [, ref, , kind, reply] = JSON.parse(String(event.data))
          if (kind !== 'phx_reply') return
          if (reply.status !== 'ok') {
            clearTimeout(timer)
            settled = true
            socket.close()
            reject(new Error(`Large OT write rejected: ${JSON.stringify(reply)}`))
          } else if (ref === '1') {
            socket.send(payload)
          } else if (ref === '2') {
            clearTimeout(timer)
            settled = true
            socket.close()
            resolve(reply.response.revision)
          }
        }
        socket.onclose = event => {
          if (settled) return
          clearTimeout(timer)
          reject(new Error(`Large OT socket closed before commit: ${event.code}`))
        }
      })
      const writeMs = performance.now() - started
      const stored = await request(`/pages/${documentPage.id}`)
      if (stored.content.plain_text !== text) throw new Error('Stored Chinese text differs from the submitted text')
      return { revision, units: text.length, frameBytes: new TextEncoder().encode(payload).length, writeMs }
    }, state.owner.uid)
    expect(result.revision).toBe(1)
    expect(result.units).toBe(6_000_000)
    expect(result.frameBytes).toBeGreaterThan(16 * 1024 * 1024)
    console.log(`Large Chinese OT measurement: ${JSON.stringify(result)}`)
  } finally {
    await context.close()
  }
})
