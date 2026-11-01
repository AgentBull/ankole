import { describe, expect, test } from 'bun:test'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  installExternalTranslationGuard,
  withExternalTranslationGuardClass
} from './external-translation-guard'

class FakeClassList {
  readonly values = new Set<string>()
  add(token: string) {
    this.values.add(token)
  }
}

class FakeElement {
  readonly attrs = new Map<string, string>()
  readonly classList = new FakeClassList()
  readonly children: FakeElement[] = []

  setAttribute(name: string, value: string) {
    this.attrs.set(name, value)
  }

  getAttribute(name: string) {
    return this.attrs.get(name) ?? null
  }

  appendChild(child: FakeElement) {
    this.children.push(child)
    return child
  }

  querySelector(selector: string) {
    if (selector === 'meta[name="google"]') {
      return this.children.find(child => child.getAttribute('name') === 'google') ?? null
    }
    return null
  }
}

describe('externalTranslationGuard', () => {
  test('marks html, body, ankole-app container, and google meta tag idempotently', () => {
    const documentElement = new FakeElement()
    const head = new FakeElement()
    const body = new FakeElement()
    const app = new FakeElement()

    const fakeDoc = {
      documentElement,
      head,
      body,
      createElement: () => new FakeElement(),
      getElementById: (id: string) => (id === 'ankole-app' ? app : null)
    } as unknown as Document

    installExternalTranslationGuard(fakeDoc)
    installExternalTranslationGuard(fakeDoc)

    expect(head.children).toHaveLength(1)
    expect(head.children[0]?.getAttribute('name')).toBe('google')
    expect(head.children[0]?.getAttribute('content')).toBe('notranslate')

    for (const el of [documentElement, body, app]) {
      expect(el.getAttribute('translate')).toBe('no')
      expect(el.getAttribute('data-immersive-translate-ignore')).toBe('')
      expect(el.classList.values.has('notranslate')).toBe(true)
    }

    expect(withExternalTranslationGuardClass('link')).toBe('link notranslate')
    expect(EXTERNAL_TRANSLATION_GUARD_ATTRS.translate).toBe('no')
  })
})
