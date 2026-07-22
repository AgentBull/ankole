import { describe, expect, mock, test } from 'bun:test'
import { BrowserRuntime } from '../src/browser-runtime'
import { renderedFetchBrowserSettings } from '../src/core/turns/rendered_fetch_runtime_config'

describe('rendered web_fetch fallback projection', () => {
  test('projects config knobs into browser settings with the full worker env', () => {
    const workerEnv = { BROWSER_BACKEND_JSON: '{"kind":"local_chromium"}', UNRELATED: 'x' }
    const settings = renderedFetchBrowserSettings({ ssrfFilter: true, renderedFetchIdleTtlMs: 45_000 }, workerEnv)
    expect(settings).toEqual({ workerEnv, ssrfFilter: true, idleTtlMs: 45_000 })
  })

  test('omits idleTtlMs when the config leaves it unset', () => {
    const settings = renderedFetchBrowserSettings({ ssrfFilter: false }, {})
    expect(settings).toEqual({ workerEnv: {}, ssrfFilter: false })
    expect('idleTtlMs' in settings).toBe(false)
  })

  test('mirrors the settings SSRF filter and forwards fetchBatch to fetchRendered unchanged', async () => {
    const runtime = new BrowserRuntime({ runtimeRoot: '/tmp/ankole-rendered-fallback-projection' })
    const fetchRendered = mock(async (..._args: unknown[]) => ({ results: [] }))
    runtime.fetchRendered = fetchRendered as unknown as typeof runtime.fetchRendered

    const settings = renderedFetchBrowserSettings({ ssrfFilter: true, renderedFetchIdleTtlMs: 10_000 }, { A: '1' })
    const fallback = runtime.renderedWebFetchFallback(settings)

    // The web-tools URL pre-filter and the browser settings share one SSRF value.
    expect(fallback.ssrfFilter).toBe(settings.ssrfFilter)

    const signal = new AbortController().signal
    await fallback.fetchBatch(['https://example.com'], signal)
    expect(fetchRendered).toHaveBeenCalledTimes(1)
    expect(fetchRendered).toHaveBeenCalledWith(['https://example.com'], settings, signal)
  })
})
