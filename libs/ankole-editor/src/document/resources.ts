import type { Element } from './tree'

export type ResourceKind = 'media'
export type MediaKind = 'image' | 'video'
export type ResourceView = 'link' | 'title' | 'card' | 'preview'

/** Empty blocks have no source yet. A patch changes only its own fields; undefined removes one. */
export type ResourceAttributes = {
  src?: string
  title?: string
  description?: string
  image?: string
  mime?: string
  size?: string
  kind?: MediaKind
  view?: ResourceView
}
export type UploadedAsset = { src: string; title?: string; mime?: string; size?: string }

/** Metadata describes one source. Replacing it clears facts about the previous source. */
export function replaceResourceSource(source: UploadedAsset): ResourceAttributes {
  return { src: source.src, mime: source.mime, size: source.size, kind: undefined }
}

/** The same image/link decision drives clipboard content and portable document exports. */
export function resourceContent(node: Element) {
  const externalEmbed = node.name === 'embed' && node.attrs.href !== undefined
  if (!externalEmbed && node.name !== 'media') return null
  const src = (externalEmbed ? node.attrs.href : node.attrs.src) ?? ''
  return {
    src,
    title: node.attrs.title || src,
    image: node.name === 'media' && mediaKind(node.attrs) === 'image'
  }
}

export function resourceText(node: Element): string | null {
  const content = resourceContent(node)
  if (!content) return null
  return content.title && content.src && content.title !== content.src
    ? `${content.title} (${content.src})`
    : content.title || content.src
}

/** Keep the canonical URL in the document and derive a provider's iframe URL only for display. */
export function webURL(value: string): string | null {
  try {
    const url = new URL(value.trim())
    return ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password ? url.href : null
  } catch {
    return null
  }
}

/** Accept an HTTP(S) URL or a bare domain (`figma.com/file/...`) and return a canonical HTTP(S) URL, or null. */
export function normalizeWebURL(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) return null
  const direct = webURL(trimmed)
  if (direct) return direct
  if (/^[^\s/:@]+\.[^\s/:]+(?:[/?#].*)?$/.test(trimmed)) {
    return webURL(`https://${trimmed}`)
  }
  return null
}

export function assetURL(value: string, resolve?: (source: string) => string): string | null {
  if (value.startsWith('ankole:asset/')) return resolve ? resolve(value) : null
  return webURL(value)
}

export function videoEmbedURL(value: string): string | null {
  const safe = webURL(value)
  if (!safe) return null
  const url = new URL(safe)
  const host = url.hostname.replace(/^www\./, '')
  const parts = url.pathname.split('/').filter(Boolean)
  if (host === 'youtube.com' || host === 'youtu.be' || host === 'youtube-nocookie.com') {
    const id =
      host === 'youtu.be'
        ? parts[0]
        : (url.searchParams.get('v') ?? (['embed', 'shorts'].includes(parts[0] ?? '') ? parts[1] : null))
    if (!id || !/^[\w-]{11}$/.test(id)) return null
    const target = new URL(`https://www.youtube-nocookie.com/embed/${id}`)
    const time = url.searchParams.get('t') ?? url.searchParams.get('start')
    if (time && /^\d+s?$/.test(time)) target.searchParams.set('start', time.replace(/s$/, ''))
    return target.href
  }
  if (host === 'vimeo.com' || host === 'player.vimeo.com') {
    const id = parts.find(part => /^\d+$/.test(part))
    if (id) return `https://player.vimeo.com/video/${id}`
  }
  return null
}

export function iframeURL(value: string): string | null {
  const safe = webURL(value)
  if (!safe) return null
  const url = new URL(safe)
  if (url.hostname === 'figma.com' || url.hostname.endsWith('.figma.com')) {
    if (url.pathname === '/embed' || url.hostname === 'embed.figma.com') return safe
    return `https://www.figma.com/embed?embed_host=ankole&url=${encodeURIComponent(safe)}`
  }
  return videoEmbedURL(safe) ?? safe
}

export function mediaKind({ src = '', mime = '', kind }: ResourceAttributes): MediaKind {
  if (kind) return kind
  if (mime.startsWith('image/')) return 'image'
  return mime.startsWith('video/') || /\.(mp4|webm|mov|m4v|ogv)(?:[?#]|$)/i.test(src) || videoEmbedURL(src)
    ? 'video'
    : 'image'
}

const SAFE_LINK_SCHEME = /^(?:https?:|mailto:|tel:|\/|#)/i

function isEdgeControlOrSpace(code: number): boolean {
  return code <= 0x20 || code === 0x7f
}

/** Return a trimmed link href when its scheme or path form is safe for DOM navigation, or null. */
export function safeLinkHref(value: string): string | null {
  let start = 0
  let end = value.length
  while (start < end && isEdgeControlOrSpace(value.charCodeAt(start))) start++
  while (end > start && isEdgeControlOrSpace(value.charCodeAt(end - 1))) end--
  if (start === end) return null
  for (let i = start; i < end; i++) {
    const code = value.charCodeAt(i)
    if (code <= 0x1f || code === 0x7f) return null
  }
  const trimmed = start === 0 && end === value.length ? value : value.slice(start, end)
  if (SAFE_LINK_SCHEME.test(trimmed) || trimmed.startsWith('ankole:page/') || trimmed.startsWith('ankole:asset/')) {
    return trimmed
  }
  return null
}
