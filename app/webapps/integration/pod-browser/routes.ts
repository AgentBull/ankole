import { podLocation } from '../../common/browser-context'
import { uuidExpand } from '../../common/uuid-url'
export { uuidShorten } from '../../common/uuid-url'

export function pageIDFromURL(url: string): string {
  const match = new URL(url).pathname.match(/^\/pages\/([^/]+)$/)
  const id = match && uuidExpand(match[1]!)
  if (!id) throw new Error('Expected a Page URL with a Kernel short UUID')
  return id
}

export const pageRoute = (id: string, chat?: string) => {
  const location = podLocation(`/pages/${id}`, { chat })
  return location.pathname + location.search
}
export const conversationRoute = (id: string) => podLocation(`/conversations/${id}`).pathname
export const listRoute = (scope: string) => podLocation(`/content/${scope}`).pathname
