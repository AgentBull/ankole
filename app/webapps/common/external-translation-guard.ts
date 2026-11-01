export const EXTERNAL_TRANSLATION_GUARD_CLASS = 'notranslate'
export const EXTERNAL_TRANSLATION_GUARD_TRANSLATE = 'no' as const

export const EXTERNAL_TRANSLATION_GUARD_ATTRS = {
  translate: EXTERNAL_TRANSLATION_GUARD_TRANSLATE,
  'data-immersive-translate-ignore': ''
} as const

export function withExternalTranslationGuardClass(className?: string): string {
  return [className, EXTERNAL_TRANSLATION_GUARD_CLASS].filter(Boolean).join(' ')
}

function markNotExternallyTranslatable(element: Element | null | undefined): void {
  if (!element) return
  element.setAttribute('translate', EXTERNAL_TRANSLATION_GUARD_TRANSLATE)
  element.setAttribute('data-immersive-translate-ignore', '')
  element.classList.add(EXTERNAL_TRANSLATION_GUARD_CLASS)
}

function ensureGoogleNotranslateMeta(doc: Document): void {
  const existing = doc.head?.querySelector<HTMLMetaElement>('meta[name="google"]')
  if (existing) {
    existing.setAttribute('content', 'notranslate')
    return
  }
  if (!doc.head) return
  const meta = doc.createElement('meta')
  meta.setAttribute('name', 'google')
  meta.setAttribute('content', 'notranslate')
  doc.head.appendChild(meta)
}

/**
 * Prevents browser and third-party DOM-rewriting translation extensions from
 * replacing React-managed text nodes inside `<font>` wrappers (which triggers
 * `NotFoundError: Failed to execute 'removeChild' on 'Node'` during streaming).
 */
export function installExternalTranslationGuard(doc: Document | undefined = globalThis.document): void {
  if (!doc) return
  ensureGoogleNotranslateMeta(doc)
  markNotExternallyTranslatable(doc.documentElement)
  markNotExternallyTranslatable(doc.body)
  markNotExternallyTranslatable(doc.getElementById('ankole-app'))
}
