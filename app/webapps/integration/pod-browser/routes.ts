import { readFileSync } from 'node:fs'
import anyAscii from 'any-ascii'
import { installPageTransliteration, podLocation, podPagePath, podPagePathnameID } from '../../common/pod-url'
export { uuidShorten } from '../../common/uuid-url'

installPageTransliteration(anyAscii)

const seededTitles = new Map<string, string>()
const statePath = process.env.POD_BROWSER_STATE_PATH
if (statePath) {
  const seeded = JSON.parse(readFileSync(statePath, 'utf8')) as {
    report_id?: string
    base_id?: string
    applet_id?: string
    runtime_test_applet_id?: string
    backend_report_id?: string
    backend_base_id?: string
    backend_applet_id?: string
    aggregate_applet_id?: string
    other_pod?: { page_id?: string }
  }
  const entries: Array<[string | undefined, string]> = [
    [seeded.report_id, 'Browser report'],
    [seeded.base_id, 'Browser sales'],
    [seeded.applet_id, 'Browser tracker'],
    [seeded.runtime_test_applet_id, 'Runtime recovery applet'],
    [seeded.backend_report_id, 'Sample operations'],
    [seeded.backend_base_id, 'Sample inventory'],
    [seeded.backend_applet_id, 'Sample reservations'],
    [seeded.aggregate_applet_id, 'Order totals'],
    [seeded.other_pod?.page_id, 'Other workspace login']
  ]
  for (const [id, title] of entries) {
    if (id) seededTitles.set(id, title)
  }
}

export function pageIDFromURL(url: string): string {
  const id = podPagePathnameID(new URL(url).pathname)
  if (!id) throw new Error('Expected a Page URL with a Kernel short UUID')
  return id
}

export const pageRoute = (id: string, chat?: string, title?: string) => {
  const location = podLocation(podPagePath(id, title ?? seededTitles.get(id)), { chat })
  return location.pathname + location.search
}
export const conversationRoute = (id: string) => podLocation(`/conversations/${id}`).pathname
export const listRoute = (scope: string) => podLocation(`/content/${scope}`).pathname
