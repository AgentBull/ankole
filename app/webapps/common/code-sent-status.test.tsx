import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import { devMailboxPath } from './browser-context'
import { CodeSentStatus } from './code-sent-status'
import i18n, { loadLocale } from './i18n'

beforeAll(async () => {
  await Promise.all([loadLocale('en-US'), loadLocale('zh-Hans-CN'), loadLocale('ja-JP'), loadLocale('ko-KR')])
})

function withDevMailboxMeta<T>(content: string | undefined, run: () => T): T {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'document')
  const fakeDocument = {
    documentElement: { lang: i18n.language || 'en-US' },
    querySelector(selector: string) {
      if (selector === 'meta[name="ankole-dev-mailbox"]' && content !== undefined) {
        return { content }
      }
      return null
    }
  }
  Object.defineProperty(globalThis, 'document', { configurable: true, value: fakeDocument })
  try {
    return run()
  } finally {
    if (previous) Object.defineProperty(globalThis, 'document', previous)
    else Reflect.deleteProperty(globalThis, 'document')
  }
}

test('CodeSentStatus appends a new-tab /dev/mailbox link only when advertised by the shell', async () => {
  const previousLanguage = i18n.language
  try {
    await i18n.changeLanguage('zh-Hans-CN')

    const expectedSent = i18n.t('auth.code_sent', { email: 'ada@example.com' })

    const withoutMailbox = withDevMailboxMeta(undefined, () =>
      renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <CodeSentStatus email="ada@example.com" />
        </I18nextProvider>
      )
    )
    expect(withoutMailbox).toContain(expectedSent)
    expect(withoutMailbox).not.toContain('/dev/mailbox')

    const withMailbox = withDevMailboxMeta('/dev/mailbox', () =>
      renderToStaticMarkup(
        <I18nextProvider i18n={i18n}>
          <CodeSentStatus email="ada@example.com" />
        </I18nextProvider>
      )
    )
    expect(withMailbox).toContain(expectedSent)
    expect(withMailbox).toContain(
      '<a href="/dev/mailbox" target="_blank" rel="noreferrer" class="link whitespace-nowrap">查看开发邮箱</a>'
    )
  } finally {
    await i18n.changeLanguage(previousLanguage)
  }
})

test('devMailboxPath accepts only origin-relative paths', () => {
  expect(withDevMailboxMeta('/dev/mailbox', () => devMailboxPath())).toBe('/dev/mailbox')
  expect(withDevMailboxMeta('//evil.example/mailbox', () => devMailboxPath())).toBeUndefined()
  expect(withDevMailboxMeta('https://evil.example/mailbox', () => devMailboxPath())).toBeUndefined()
  expect(withDevMailboxMeta('', () => devMailboxPath())).toBeUndefined()
})
