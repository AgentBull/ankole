import type { LinkMetadata } from '@ankole/block-editor/editor'

/** Fetch and parse HTML metadata for same-origin URLs in the standalone editor playground. */
export async function resolvePlaygroundLinkMetadata(url: string, signal?: AbortSignal): Promise<LinkMetadata | null> {
  if (typeof window === 'undefined') return null
  let parsed: URL
  try {
    parsed = new URL(url, window.location.href)
  } catch {
    return null
  }
  if (parsed.origin !== window.location.origin) return null
  const response = await fetch(parsed.href, { signal, headers: { Accept: 'text/html,application/xhtml+xml' } })
  if (!response.ok) return null
  const contentType = response.headers.get('content-type') ?? ''
  if (contentType && !contentType.includes('text/html') && !contentType.includes('application/xhtml+xml')) {
    return null
  }
  const html = await response.text()
  const doc = new DOMParser().parseFromString(html, 'text/html')
  const meta = (selector: string) => doc.querySelector(selector)?.getAttribute('content')?.trim() || undefined
  const toAbsolute = (candidate?: string | null) => {
    if (!candidate?.trim()) return undefined
    try {
      return new URL(candidate.trim(), response.url || parsed.href).href
    } catch {
      return undefined
    }
  }
  const title =
    meta('meta[property="og:title"]') ??
    meta('meta[name="twitter:title"]') ??
    (doc.title.replace(/\s+/g, ' ').trim() || undefined)
  const description =
    meta('meta[property="og:description"]') ??
    meta('meta[name="twitter:description"]') ??
    meta('meta[name="description"]')
  const image = toAbsolute(meta('meta[property="og:image"]') ?? meta('meta[name="twitter:image"]'))
  const icon =
    toAbsolute(
      doc.querySelector('link[rel~="icon"]')?.getAttribute('href') ??
        doc.querySelector('link[rel="apple-touch-icon"]')?.getAttribute('href')
    ) ?? `${parsed.origin}/favicon.ico`
  return { title, description, image, icon }
}
