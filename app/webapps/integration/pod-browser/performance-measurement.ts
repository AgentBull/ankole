import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import type { CDPSession, Page } from '@playwright/test'
import { state } from './fixtures'

const allProfiles = [
  { name: 'local', viewport: { width: 1440, height: 900 }, mobile: false, cpu: 1, latency: 0, mbps: 0 },
  { name: 'desktop', viewport: { width: 1440, height: 900 }, mobile: false, cpu: 1, latency: 40, mbps: 10 },
  { name: 'mobile', viewport: { width: 390, height: 844 }, mobile: true, cpu: 4, latency: 150, mbps: 1.6 }
] as const

export const profiles = allProfiles.filter(profile =>
  process.env.POD_PERFORMANCE_PROFILE ? profile.name === process.env.POD_PERFORMANCE_PROFILE : profile.name !== 'local'
)
if (!profiles.length) throw new Error('Unknown POD_PERFORMANCE_PROFILE')

type Profile = (typeof allProfiles)[number]

type Resource = {
  url: string
  type: string
  status?: number
  mimeType?: string
  contentType?: string
  contentEncoding?: string
  cacheControl?: string
  encodedBytes?: number
  diskCache?: boolean
  serviceWorker?: boolean
  servedFromCache?: boolean
  failure?: string
}

export async function instrument(page: Page, cdp: CDPSession, profile: Profile) {
  const resources = new Map<string, Resource>()
  cdp.on('Network.requestWillBeSent', event => {
    const url = new URL(event.request.url)
    resources.set(event.requestId, {
      url: url.origin === state.base_url ? url.pathname : url.origin + url.pathname,
      type: event.type ?? 'Other'
    })
  })
  cdp.on('Network.responseReceived', event => {
    const header = (name: string) =>
      Object.entries(event.response.headers).find(([key]) => key.toLowerCase() === name)?.[1]
    Object.assign(resources.get(event.requestId) ?? {}, {
      status: event.response.status,
      mimeType: event.response.mimeType,
      contentType: header('content-type'),
      contentEncoding: header('content-encoding'),
      cacheControl: header('cache-control'),
      diskCache: event.response.fromDiskCache ?? false,
      serviceWorker: event.response.fromServiceWorker ?? false
    })
  })
  cdp.on('Network.loadingFinished', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.encodedBytes = event.encodedDataLength
  })
  cdp.on('Network.requestServedFromCache', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.servedFromCache = true
  })
  cdp.on('Network.loadingFailed', event => {
    const resource = resources.get(event.requestId)
    if (resource) resource.failure = event.errorText
  })
  await cdp.send('Network.enable')
  await cdp.send('Network.clearBrowserCache')
  await cdp.send('Network.setCacheDisabled', { cacheDisabled: true })
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: profile.cpu })
  if (profile.name !== 'local') {
    await cdp.send('Network.emulateNetworkConditions', {
      offline: false,
      latency: profile.latency,
      downloadThroughput: (profile.mbps * 1_000_000) / 8,
      uploadThroughput: 750_000 / 8,
      connectionType: profile.mobile ? 'cellular4g' : 'wifi'
    })
  }
  await page.addInitScript({
    content: `${readFileSync(fileURLToPath(new URL('./web-vitals.iife.js', import.meta.resolve('web-vitals'))), 'utf8')}
    window.__podVitals = {};
    for (const name of ['LCP', 'INP', 'CLS']) {
      webVitals['on' + name](metric => {
        window.__podVitals[name] = { value: metric.value, rating: metric.rating };
      }, { reportAllChanges: true, durationThreshold: 16 });
    }
  `
  })
  await page.addInitScript(() => {
    performance.setResourceTimingBufferSize(5000)
    const metrics = {
      shifts: [] as { value: number; startTime: number; recentInput: boolean }[],
      lcp: [] as { startTime: number; size: number; tag: string; id: string }[],
      events: [] as {
        name: string
        startTime: number
        duration: number
        inputDelay: number
        processingTime: number
        interactionID: number
      }[],
      longTasks: [] as { startTime: number; duration: number }[]
    }
    Object.assign(window, { __podPerformance: metrics })
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & { value: number; hadRecentInput: boolean }
        metrics.shifts.push({ value: entry.value, startTime: entry.startTime, recentInput: entry.hadRecentInput })
      }
    }).observe({ type: 'layout-shift', buffered: true })
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & { size: number; element?: Element }
        metrics.lcp.push({
          startTime: entry.startTime,
          size: entry.size,
          tag: entry.element?.tagName ?? '',
          id: entry.element?.id ?? ''
        })
      }
    }).observe({ type: 'largest-contentful-paint', buffered: true })
    new PerformanceObserver(list => {
      for (const raw of list.getEntries()) {
        const entry = raw as PerformanceEntry & {
          interactionId: number
          processingStart: number
          processingEnd: number
        }
        if (!entry.interactionId) continue
        metrics.events.push({
          name: entry.name,
          startTime: entry.startTime,
          duration: entry.duration,
          inputDelay: entry.processingStart - entry.startTime,
          processingTime: entry.processingEnd - entry.processingStart,
          interactionID: entry.interactionId
        })
      }
    }).observe({ type: 'event', buffered: true, durationThreshold: 16 } as PerformanceObserverInit)
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) {
        metrics.longTasks.push({ startTime: entry.startTime, duration: entry.duration })
      }
    }).observe({ type: 'longtask', buffered: true })
  })
  return resources
}

export async function snapshot(page: Page) {
  return page.evaluate(() => {
    const metrics = (window as Window & { __podPerformance?: unknown }).__podPerformance
    return {
      metrics,
      vitals: (window as Window & { __podVitals?: Record<string, { value: number; rating: string }> }).__podVitals,
      now: performance.now(),
      timeOrigin: performance.timeOrigin,
      navigation: performance.getEntriesByType('navigation').map(entry => entry.toJSON()),
      paints: performance.getEntriesByType('paint').map(entry => entry.toJSON()),
      resources: performance.getEntriesByType('resource').map(raw => {
        const entry = raw as PerformanceResourceTiming
        const url = new URL(entry.name)
        url.searchParams.delete('authentication_ref')
        return {
          url: url.origin === location.origin ? url.pathname + url.search : url.origin + url.pathname,
          startTime: entry.startTime,
          responseEnd: entry.responseEnd,
          duration: entry.duration,
          ttfb: entry.responseStart - entry.requestStart,
          transferSize: entry.transferSize,
          encodedBodySize: entry.encodedBodySize,
          decodedBodySize: entry.decodedBodySize,
          initiatorType: entry.initiatorType
        }
      }),
      fontStatus: document.fonts.status,
      fontFamilies: [...document.fonts].map(font => ({ family: font.family, status: font.status })),
      bodyFontFamily: getComputedStyle(document.body).fontFamily
    }
  })
}

/** Let the final paint and web-vitals' idle reporting complete before reading. */
export async function finalSnapshot(page: Page) {
  await page.evaluate(
    () =>
      new Promise<void>(resolve => {
        requestAnimationFrame(() =>
          requestAnimationFrame(() => requestIdleCallback(() => resolve(), { timeout: 1000 }))
        )
      })
  )
  return snapshot(page)
}
