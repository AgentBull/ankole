import { expect, spyOn, test } from 'bun:test'
import { BrowserSession } from '../src/browser/browser-session'

test('a page creation failure preserves completed siblings and later results in request order', async () => {
  const urls = ['https://example.com/first', 'https://example.com/second', 'https://example.com/failed']
  urls.push(urls[0]!)
  let now = 1_000_000
  const clock = spyOn(Date, 'now').mockImplementation(() => now)
  const closed: number[] = []
  let closedBeforeFailure: number[] = []
  let attempts = 0
  // Browser I/O, dialog state and time are unit fakes; execute and extraction use the real methods.
  const session = Object.assign(Object.create(BrowserSession.prototype) as BrowserSession, {
    material: {
      backend: { kind: 'local_chromium' },
      navigation: { ssrf_filter: false, allow_file_urls: false }
    },
    guard: {
      hasPending: () => false,
      withAutomaticDialogs: async (run: () => Promise<void>) => run()
    },
    registry: {
      async newPage() {
        const index = ++attempts
        if (index === 3) {
          closedBeforeFailure = [...closed]
          throw new Error('Page capacity reached')
        }
        let url = ''
        return {
          async goto(value: string) {
            url = value
          },
          locator: () => ({ innerText: async () => `Page ${index} text` }),
          async waitForTimeout(milliseconds: number) {
            now += milliseconds
          },
          title: async () => `Page ${index}`,
          url: () => url,
          async close() {
            closed.push(index)
          }
        }
      }
    }
  })
  try {
    const result = await session.execute({ name: 'fetch', args: { urls } }, now + 30_000)
    expect(result).toMatchObject({
      success: false,
      results: [
        { url: urls[0], title: 'Page 1', text: 'Page 1 text' },
        { url: urls[1], title: 'Page 2', text: 'Page 2 text' },
        { url: urls[2], error: 'Page capacity reached', error_code: 'internal', retryable: false },
        { url: urls[3], title: 'Page 4', text: 'Page 4 text' }
      ]
    })
    expect(closedBeforeFailure.toSorted()).toEqual([1, 2])
    expect(closed.toSorted()).toEqual([1, 2, 4])
    expect(attempts).toBe(4)
  } finally {
    clock.mockRestore()
  }
})
