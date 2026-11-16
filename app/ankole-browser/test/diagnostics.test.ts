import { describe, expect, test } from 'bun:test'
import { EventEmitter } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { BrowserContext, CDPSession, ConsoleMessage, Download, Frame, Page, Route } from 'playwright-core'
import { DiagnosticsStore, redactDiagnosticURL } from '../src/browser/diagnostics'
import { compileQueryFilter } from '../src/browser/query-filter'
import { NetworkPolicyController } from '../src/browser/navigation-policy'
import { callWebMCPTool, listWebMCPTools } from '../src/browser/webmcp'
import type { BrowserMaterial } from '../src/protocol'

const localMaterial: BrowserMaterial = {
  protocol_version: 1,
  route_id: 'br_1234567890abcdef',
  data_root: '/tmp/ankole-browser-diagnostics-test/data',
  artifact_root: '/tmp/ankole-browser-diagnostics-test/artifacts',
  immutable_fingerprint: 'sha256:test',
  material_generation: 0,
  profile: { mode: 'persistent_user_data_dir' },
  backend: { kind: 'local_chromium', executable: '/bin/true', args: [] },
  navigation: { ssrf_filter: true, allow_file_urls: false },
  idle_ttl_ms: 60_000
}

const kitesurfRemoteMaterial: BrowserMaterial = {
  ...localMaterial,
  backend: {
    kind: 'remote_cdp',
    endpoint: 'wss://kitesurf.example.workers.dev/devtools/browser',
    headers: {},
    connect_timeout_ms: 5_000,
    session_identity: 'kitesurf-stateless'
  }
}

describe('diagnostics redaction and query filters', () => {
  test('redactDiagnosticURL strips credentials and sensitive query or hash tokens while preserving safe parameters', () => {
    const redacted = redactDiagnosticURL(
      'https://alice:hunter2@api.example.com/v1/export?page=2&api_key=sk_live_123&x-amz-signature=abc&sort=desc#access_token=tok_999'
    )
    expect(redacted).toBe(
      'https://api.example.com/v1/export?page=2&api_key=[REDACTED]&x-amz-signature=[REDACTED]&sort=desc#[REDACTED]'
    )
    expect(redacted).not.toContain('alice')
    expect(redacted).not.toContain('hunter2')
    expect(redacted).not.toContain('sk_live_123')
    expect(redacted).not.toContain('tok_999')

    expect(redactDiagnosticURL('data:text/html;base64,PHNjcmlwdD4=')).toBe('data:[redacted]')
    expect(redactDiagnosticURL('blob:https://example.com/1234-5678')).toBe('blob:[redacted]')

    const camelRedacted = redactDiagnosticURL(
      'wss://user:pw@realtime.example.com/socket?accessToken=at_1&refreshToken=rt_2&idToken=id_3&clientSecret=cs_4&sessionId=sid_5&authToken=au_6&privateKey=pk_7&xApiKey=xk_8&userId=u_safe#sessionId=hash_sid'
    )
    expect(camelRedacted).toBe(
      'wss://realtime.example.com/socket?accessToken=[REDACTED]&refreshToken=[REDACTED]&idToken=[REDACTED]&clientSecret=[REDACTED]&sessionId=[REDACTED]&authToken=[REDACTED]&privateKey=[REDACTED]&xApiKey=[REDACTED]&userId=u_safe#[REDACTED]'
    )
  })

  test('DiagnosticsStore redacts ws:// and wss:// URLs embedded in console error messages', async () => {
    const store = new DiagnosticsStore('/tmp/ankole-browser-diagnostics-ws-test')
    const consoleListeners: Array<(msg: ConsoleMessage) => void> = []
    const fakePage = {
      on: (event: string, cb: (arg: never) => void) => {
        if (event === 'console') consoleListeners.push(cb as unknown as (msg: ConsoleMessage) => void)
      },
      url: () => 'https://app.example.com/live'
    } as unknown as Page
    store.installPage(fakePage)

    consoleListeners[0]!({
      type: () => 'error',
      text: () =>
        'Socket dropped: ws://alice:pw@127.0.0.1:8787/stream?accessToken=ws_secret_1 and wss://api.example.com/ws?xApiKey=ws_secret_2',
      location: () => ({ url: 'https://app.example.com/app.js?authToken=loc_secret' })
    } as unknown as ConsoleMessage)

    const report = await store.read()
    const serialized = JSON.stringify(report)
    expect(serialized).not.toContain('ws_secret_1')
    expect(serialized).not.toContain('ws_secret_2')
    expect(serialized).not.toContain('loc_secret')
    expect(serialized).not.toContain('alice')
    expect(serialized).toContain('ws://127.0.0.1:8787/stream?accessToken=[REDACTED]')
    expect(serialized).toContain('wss://api.example.com/ws?xApiKey=[REDACTED]')
    expect(serialized).toContain('https://app.example.com/app.js?authToken=[REDACTED]')
  })

  test('compileQueryFilter supports substring, slash regex, and bracketed state literals', () => {
    const substring = compileQueryFilter('Confirm Order')
    expect(substring('- button "Confirm order" [ref=e4]')).toBe(true)
    expect(substring('- button "Cancel" [ref=e5]')).toBe(false)

    const regex = compileQueryFilter('/(error|5\\d\\d)/i')
    expect(regex('GET https://api.example.com/items 503')).toBe(true)
    expect(regex('GET https://api.example.com/items 200')).toBe(false)

    const bracketLiteral = compileQueryFilter('[expanded=true]')
    expect(bracketLiteral('- combobox "Plan" [ref=e2] [expanded=true]')).toBe(true)
    expect(bracketLiteral('- combobox "Plan" [ref=e2] [expanded=false]')).toBe(false)

    const dotLiteral = compileQueryFilter('report.csv')
    expect(dotLiteral('- link "Download report.csv" [ref=e6]')).toBe(true)
    expect(dotLiteral('- link "Download reportXcsv" [ref=e7]')).toBe(false)

    const charClassLiteral = compileQueryFilter('[VIP]')
    expect(charClassLiteral('- badge "[VIP] Customer" [ref=e8]')).toBe(true)
    expect(charClassLiteral('- button "Save" [ref=e9]')).toBe(false)

    expect(() => compileQueryFilter('/[unclosed/')).toThrow('invalid regular expression')
  })
})

describe('NetworkPolicyController local vs stateless remote_cdp routing', () => {
  test('remote_cdp installs zero global routes by default and attaches/detaches media route on demand', async () => {
    const routes: Array<(route: Route) => Promise<void>> = []
    let unrouted = 0
    const context = {
      route: async (_pattern: string, handler: (route: Route) => Promise<void>) => {
        routes.push(handler)
      },
      unroute: async (_pattern: string, handler: (route: Route) => Promise<void>) => {
        const idx = routes.indexOf(handler)
        if (idx !== -1) routes.splice(idx, 1)
        unrouted += 1
      }
    } as unknown as BrowserContext

    const controller = new NetworkPolicyController(context, kitesurfRemoteMaterial)
    await controller.install()
    // Stateless remote CDP backends (such as Kitesurf) must not incur per-subresource Fetch.enable round-trips.
    expect(routes).toHaveLength(0)
    expect(controller.status()).toEqual({ mode: 'default', blocked_resource_types: [] })

    const enabled = await controller.setMode('no-media')
    expect(enabled).toEqual({ mode: 'no-media', blocked_resource_types: ['image', 'media', 'font'] })
    expect(routes).toHaveLength(1)

    // Verify the remote media handler aborts images while continuing XHR/document requests.
    const imageDecision = await simulateRoute(routes[0]!, {
      url: 'https://cdn.example.com/hero.webp',
      resourceType: 'image',
      isNavigation: false
    })
    expect(imageDecision).toBe('aborted')
    const apiDecision = await simulateRoute(routes[0]!, {
      url: 'https://api.example.com/data.json',
      resourceType: 'fetch',
      isNavigation: false
    })
    expect(apiDecision).toBe('continued')

    const restored = await controller.setMode('default')
    expect(restored).toEqual({ mode: 'default', blocked_resource_types: [] })
    expect(routes).toHaveLength(0)
    expect(unrouted).toBe(1)

    // Best-effort rendered_fallback page route tolerates stateless backends that reject Fetch.enable.
    const statelessPage = {
      route: async () => {
        throw new Error('Protocol error (Fetch.enable): Method not found')
      }
    } as unknown as Page
    await expect(controller.prepareRenderedFetchPage(statelessPage)).resolves.toBeUndefined()
  })

  test('local_chromium blocks media on rendered_fallback pages without affecting interactive pages', async () => {
    let installedHandler: ((route: Route) => Promise<void>) | undefined
    const context = {
      route: async (_pattern: string, handler: (route: Route) => Promise<void>) => {
        installedHandler = handler
      }
    } as unknown as BrowserContext

    const controller = new NetworkPolicyController(context, localMaterial)
    await controller.install()
    expect(installedHandler).toBeDefined()

    const interactivePage = {} as Page
    const extractionPage = {} as Page
    await controller.prepareRenderedFetchPage(extractionPage)

    expect(
      await simulateRoute(installedHandler!, {
        url: 'https://8.8.8.8/banner.png',
        resourceType: 'image',
        isNavigation: false,
        page: extractionPage
      })
    ).toBe('aborted')

    expect(
      await simulateRoute(installedHandler!, {
        url: 'https://8.8.8.8/banner.png',
        resourceType: 'image',
        isNavigation: false,
        page: interactivePage
      })
    ).toBe('continued')

    await controller.setMode('no-media')
    expect(
      await simulateRoute(installedHandler!, {
        url: 'https://8.8.8.8/banner.png',
        resourceType: 'image',
        isNavigation: false,
        page: interactivePage
      })
    ).toBe('aborted')
  })
})

describe('WebMCP CDP protocol contract (Kitesurf wire compatibility)', () => {
  test('discovers deferred WebMCP.toolsAdded announcements, invokes tools, and cancels timed-out invocations', async () => {
    const sentMethods: Array<{ method: string; params: unknown }> = []

    function createMockPage(behavior: 'normal' | 'hang' | 'unsupported'): { page: Page; frame: Frame } {
      const emitter = new EventEmitter()
      const cdp = Object.assign(emitter, {
        send: async (method: string, params: Record<string, unknown> = {}) => {
          sentMethods.push({ method, params })
          if (behavior === 'unsupported' && method === 'WebMCP.enable') {
            throw new Error("Protocol error (WebMCP.enable): 'WebMCP.enable' wasn't found (-32601)")
          }
          if (method === 'WebMCP.enable') {
            // Match Kitesurf's afterReply timer behavior in packages/engine/src/cdp/webmcp.ts.
            setTimeout(() => {
              emitter.emit('WebMCP.toolsAdded', {
                tools: [
                  {
                    name: 'lookup_flight',
                    description: 'Search flights by route',
                    frameId: 'frame-main',
                    inputSchema: { type: 'object', properties: { origin: { type: 'string' } } }
                  }
                ]
              })
            }, 0)
            return {}
          }
          if (method === 'Page.getFrameTree') {
            return { frameTree: { frame: { id: 'frame-main' } } }
          }
          if (method === 'WebMCP.invokeTool') {
            const invocationId = 'inv-123'
            if (behavior === 'normal') {
              setTimeout(() => {
                emitter.emit('WebMCP.toolResponded', {
                  invocationId,
                  status: 'Completed',
                  output: { flights: [{ code: 'KS101' }], echo: params.input }
                })
              }, 5)
            }
            return { invocationId }
          }
          return {}
        },
        detach: async () => undefined
      }) as unknown as CDPSession

      const frame = {
        evaluate: async () => ({
          supported: false,
          protocol: 'none' as const,
          tools: []
        })
      } as unknown as Frame

      const page = {
        context: () => ({
          newCDPSession: async () => cdp
        })
      } as unknown as Page

      return { page, frame }
    }

    const normal = createMockPage('normal')
    const listed = await listWebMCPTools(normal.page, normal.frame, Date.now() + 2_000)
    expect(listed).toEqual({
      supported: true,
      protocol: 'cdp',
      tools: [
        {
          name: 'lookup_flight',
          description: 'Search flights by route',
          frame_id: 'frame-main',
          input_schema: { type: 'object', properties: { origin: { type: 'string' } } }
        }
      ]
    })

    const invoked = await callWebMCPTool(
      normal.page,
      normal.frame,
      'lookup_flight',
      { origin: 'SFO' },
      Date.now() + 2_000
    )
    expect(invoked).toEqual({
      protocol: 'cdp',
      tool: 'lookup_flight',
      output: { flights: [{ code: 'KS101' }], echo: { origin: 'SFO' } }
    })

    sentMethods.length = 0
    const hanging = createMockPage('hang')
    await expect(
      callWebMCPTool(hanging.page, hanging.frame, 'lookup_flight', { origin: 'NRT' }, Date.now() + 80)
    ).rejects.toMatchObject({ code: 'timeout', retryable: true })
    expect(sentMethods.some(entry => entry.method === 'WebMCP.cancelInvocation')).toBe(true)

    const unsupported = createMockPage('unsupported')
    expect(await listWebMCPTools(unsupported.page, unsupported.frame, Date.now() + 1_000)).toEqual({
      supported: false,
      protocol: 'none',
      tools: []
    })
  })

  test('isolates same-named WebMCP tools per frame regardless of announcement order and waits event-driven past 35ms', async () => {
    const invocations: Array<{ frameId?: string; toolName?: string; input?: unknown }> = []

    const frameA = {
      name: () => 'editor-left',
      url: () => 'https://app.example.com/frame-a',
      childFrames: () => [],
      evaluate: async () => ({ supported: false, protocol: 'none' as const, tools: [] })
    } as unknown as Frame

    const frameB = {
      name: () => 'editor-right',
      url: () => 'https://app.example.com/frame-b',
      childFrames: () => [],
      evaluate: async () => ({ supported: false, protocol: 'none' as const, tools: [] })
    } as unknown as Frame

    const mainFrame = {
      name: () => '',
      url: () => 'https://app.example.com/',
      childFrames: () => [frameA, frameB],
      evaluate: async () => ({ supported: false, protocol: 'none' as const, tools: [] })
    } as unknown as Frame

    const page = {
      mainFrame: () => mainFrame,
      context: () => ({
        newCDPSession: async () => {
          const emitter = new EventEmitter()
          return Object.assign(emitter, {
            send: async (method: string, params: Record<string, unknown> = {}) => {
              if (method === 'WebMCP.enable') {
                // Frame A announces immediately, then Frame B announces the same `save` tool 60ms later
                // (past the old hardcoded 35ms sleep), and Frame B's announcement must NOT clobber Frame A.
                setTimeout(() => {
                  emitter.emit('WebMCP.toolsAdded', {
                    tools: [{ name: 'save', description: 'Save left pane', frameId: 'cdp-frame-a' }]
                  })
                }, 5)
                setTimeout(() => {
                  emitter.emit('WebMCP.toolsAdded', {
                    tools: [{ name: 'save', description: 'Save right pane', frameId: 'cdp-frame-b' }]
                  })
                }, 60)
                return {}
              }
              if (method === 'Page.getFrameTree') {
                return {
                  frameTree: {
                    frame: { id: 'cdp-main', name: '', url: 'https://app.example.com/' },
                    childFrames: [
                      { frame: { id: 'cdp-frame-a', name: 'editor-left', url: 'https://app.example.com/frame-a' } },
                      { frame: { id: 'cdp-frame-b', name: 'editor-right', url: 'https://app.example.com/frame-b' } }
                    ]
                  }
                }
              }
              if (method === 'WebMCP.invokeTool') {
                invocations.push({
                  frameId: String(params.frameId),
                  toolName: String(params.toolName),
                  input: params.input
                })
                const invocationId = `inv-${invocations.length}`
                setTimeout(() => {
                  emitter.emit('WebMCP.toolResponded', {
                    invocationId,
                    status: 'Completed',
                    output: { savedIn: params.frameId }
                  })
                }, 5)
                return { invocationId }
              }
              return {}
            },
            detach: async () => undefined
          }) as unknown as CDPSession
        }
      })
    } as unknown as Page

    // Calling `save` on frameB waits past 35ms for `cdp-frame-b`'s announcement instead of hitting `cdp-frame-a`.
    const resB = await callWebMCPTool(page, frameB, 'save', { doc: 'right' }, Date.now() + 2_000)
    expect(resB).toEqual({ protocol: 'cdp', tool: 'save', output: { savedIn: 'cdp-frame-b' } })

    // Calling `save` on frameA still targets `cdp-frame-a` even if `cdp-frame-b` also announces `save`.
    const resA = await callWebMCPTool(page, frameA, 'save', { doc: 'left' }, Date.now() + 2_000)
    expect(resA).toEqual({ protocol: 'cdp', tool: 'save', output: { savedIn: 'cdp-frame-a' } })

    const listB = await listWebMCPTools(page, frameB, Date.now() + 2_000)
    expect(listB.tools).toEqual([{ name: 'save', description: 'Save right pane', frame_id: 'cdp-frame-b' }])
    expect(invocations).toEqual([
      { frameId: 'cdp-frame-b', toolName: 'save', input: { doc: 'right' } },
      { frameId: 'cdp-frame-a', toolName: 'save', input: { doc: 'left' } }
    ])
  })

  test('evaluates page-realm WebMCP discovery at most once when CDP WebMCP is absent or empty', async () => {
    let evaluateCount = 0
    const frame = {
      evaluate: async () => {
        evaluateCount += 1
        return {
          supported: true,
          protocol: 'declarative_dom' as const,
          tools: [{ name: 'submit_form', description: 'Submit form' }]
        }
      }
    } as unknown as Frame

    const nonCdpPage = { context: () => ({}) } as unknown as Page
    expect(await listWebMCPTools(nonCdpPage, frame, Date.now() + 1_000)).toEqual({
      supported: true,
      protocol: 'declarative_dom',
      tools: [{ name: 'submit_form', description: 'Submit form' }]
    })
    expect(evaluateCount).toBe(1)

    evaluateCount = 0
    const emptyCdpPage = {
      context: () => ({
        newCDPSession: async () =>
          Object.assign(new EventEmitter(), {
            send: async () => ({}),
            detach: async () => undefined
          }) as unknown as CDPSession
      })
    } as unknown as Page
    expect(await listWebMCPTools(emptyCdpPage, frame, Date.now() + 1_000)).toEqual({
      supported: true,
      protocol: 'declarative_dom',
      tools: [{ name: 'submit_form', description: 'Submit form' }]
    })
    expect(evaluateCount).toBe(1)
  })
})

describe('DiagnosticsStore atomic concurrent download archiving', () => {
  test('allocates distinct filenames without overwriting when identical downloads arrive concurrently', async () => {
    const tempRoot = await mkdtemp(join(tmpdir(), 'ankole-browser-dl-race-'))
    try {
      const store = new DiagnosticsStore(tempRoot)
      const listeners: Array<(download: Download) => void> = []
      const fakePage = {
        on: (event: string, cb: (arg: never) => void) => {
          if (event === 'download') listeners.push(cb as unknown as (download: Download) => void)
        },
        url: () => 'https://example.com/reports'
      } as unknown as Page

      store.installPage(fakePage)
      expect(listeners).toHaveLength(1)

      const makeFakeDownload = (payload: string): Download =>
        ({
          url: () => 'https://example.com/export?token=secret123',
          suggestedFilename: () => 'report.csv',
          failure: async () => null,
          saveAs: async (targetPath: string) => {
            await Bun.sleep(15)
            await writeFile(targetPath, payload, 'utf8')
          }
        }) as unknown as Download

      const { downloads: captured } = await store.captureDownloadsDuring(Date.now() + 3_000, 0, async () => {
        listeners[0]!(makeFakeDownload('first,1\n'))
        listeners[0]!(makeFakeDownload('second,2\n'))
      })
      expect(captured).toHaveLength(2)
      const filenames = captured.map(item => item.filename).sort()
      expect(filenames).toEqual(['report-2.csv', 'report.csv'])

      const contents = await Promise.all(captured.map(item => readFile(item.path!, 'utf8')))
      expect(contents.sort()).toEqual(['first,1\n', 'second,2\n'])
    } finally {
      await rm(tempRoot, { recursive: true, force: true })
    }
  })

  test('captureDownloadsDuring isolates action windows on error and never leaks earlier inflight downloads, while close awaits writes', async () => {
    const tempRoot = await mkdtemp(join(tmpdir(), 'ankole-browser-dl-isolation-'))
    try {
      const store = new DiagnosticsStore(tempRoot)
      const listeners: Array<(download: Download) => void> = []
      const fakePage = {
        on: (event: string, cb: (arg: never) => void) => {
          if (event === 'download') listeners.push(cb as unknown as (download: Download) => void)
        },
        url: () => 'https://example.com/reports'
      } as unknown as Page
      store.installPage(fakePage)

      let releaseSlowSave!: () => void
      const slowSaveGate = new Promise<void>(resolveGate => {
        releaseSlowSave = resolveGate
      })
      let slowSaveFinished = false

      // Start a slow background download outside the next action window.
      listeners[0]!({
        url: () => 'https://example.com/slow.zip',
        suggestedFilename: () => 'slow.zip',
        failure: async () => null,
        saveAs: async (targetPath: string) => {
          await slowSaveGate
          await writeFile(targetPath, 'slow-bytes', 'utf8')
          slowSaveFinished = true
        }
      } as unknown as Download)

      // An action that throws resets its capture window cleanly.
      await expect(
        store.captureDownloadsDuring(Date.now() + 1_000, 0, async () => {
          throw new Error('dialog_blocked')
        })
      ).rejects.toThrow('dialog_blocked')

      // A subsequent non-downloading action returns [] immediately without inheriting slow.zip.
      const nonDownloading = await store.captureDownloadsDuring(Date.now() + 1_000, 0, async () => 'filled')
      expect(nonDownloading).toEqual({ result: 'filled', downloads: [] })
      expect(slowSaveFinished).toBe(false)

      // close() waits for the inflight saveAs write to finish before returning.
      setTimeout(() => releaseSlowSave(), 20)
      await store.close()
      expect(slowSaveFinished).toBe(true)
    } finally {
      await rm(tempRoot, { recursive: true, force: true })
    }
  })
})

async function simulateRoute(
  handler: (route: Route) => Promise<void>,
  spec: { url: string; resourceType: string; isNavigation: boolean; page?: Page }
): Promise<'continued' | 'aborted'> {
  let decision: 'continued' | 'aborted' | undefined
  const route = {
    request: () => ({
      url: () => spec.url,
      resourceType: () => spec.resourceType,
      isNavigationRequest: () => spec.isNavigation,
      frame: () => (spec.page ? { page: () => spec.page } : null)
    }),
    continue: async () => {
      decision = 'continued'
    },
    abort: async () => {
      decision = 'aborted'
    }
  } as unknown as Route
  await handler(route)
  if (!decision) throw new Error('route handler neither continued nor aborted')
  return decision
}
