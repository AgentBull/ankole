/**
 * The messages an embedded Base Page sends to the page that frames it.
 *
 * Every message is `{ source: 'ankole-embed', type, ... }`:
 * - `loaded` once the Base Page has rendered,
 * - `height` with the content height in CSS pixels whenever it changes,
 * - `unauthenticated` when the browser has no Pod session (the host page opens sign-in at the top level),
 * - `forbidden` when the Page is missing, is not a Base, or the person may not read it.
 *
 * The bridge posts only to a framing origin that the Pod lists in `pod.embed_origins`, so a page
 * outside that list never receives these messages even if a browser lets it frame the Pod.
 */
export type EmbedMessage =
  | { type: 'loaded'; pageID: string }
  | { type: 'height'; height: number }
  | { type: 'unauthenticated' }
  | { type: 'forbidden'; pageID?: string }

export const EMBED_SOURCE = 'ankole-embed'

export type EmbedBridge = {
  readonly target: string | undefined
  post(message: EmbedMessage): void
}

/** Finds the origin of the framing page, if the Pod allows it. */
export function embedTarget(
  allowed: readonly string[],
  ancestorOrigins: ArrayLike<string> | undefined,
  referrer: string
): string | undefined {
  let parent = ancestorOrigins && ancestorOrigins.length > 0 ? ancestorOrigins[0] : undefined
  if (!parent && referrer) {
    try {
      parent = new URL(referrer).origin
    } catch {
      parent = undefined
    }
  }
  return parent && allowed.includes(parent) ? parent : undefined
}

export function readEmbedOrigins(doc: Document = document): string[] {
  try {
    const value: unknown = JSON.parse(
      doc.querySelector('meta[name="ankole-embed-origins"]')?.getAttribute('content') ?? '[]'
    )
    return Array.isArray(value) ? value.filter((origin): origin is string => typeof origin === 'string') : []
  } catch {
    return []
  }
}

export function createEmbedBridge(
  parent: { postMessage(message: unknown, targetOrigin: string): void } | null,
  target: string | undefined
): EmbedBridge {
  let lastHeight: number | undefined
  return {
    target,
    post(message) {
      if (!parent || !target) return
      if (message.type === 'height') {
        if (message.height === lastHeight) return
        lastHeight = message.height
      }
      parent.postMessage({ source: EMBED_SOURCE, ...message }, target)
    }
  }
}

/** Builds the bridge for this document from its shell and the browser's framing facts. */
export function windowEmbedBridge(): EmbedBridge {
  const framed = window.parent !== window
  const target = framed
    ? embedTarget(readEmbedOrigins(), window.location.ancestorOrigins, document.referrer)
    : undefined
  return createEmbedBridge(framed ? window.parent : null, target)
}
