import { describe, expect, test } from 'bun:test'
import i18n from 'i18next'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { isSaveShortcut } from './content-context'
import { DocumentPresence } from './document-presence'
import { DocumentPresenceModel } from './state/document-presence'

describe('Page manual save shortcut and top-bar status', () => {
  test('isSaveShortcut matches Mod+S across macOS and Windows/Linux without swallowing modified chords', () => {
    expect(isSaveShortcut({ key: 's', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false })).toBe(true)
    expect(isSaveShortcut({ key: 'S', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false })).toBe(true)
    expect(isSaveShortcut({ key: 's', metaKey: false, ctrlKey: true, altKey: false, shiftKey: false })).toBe(true)
    expect(isSaveShortcut({ key: 'S', metaKey: false, ctrlKey: true, altKey: false, shiftKey: false })).toBe(true)

    expect(isSaveShortcut({ key: 's', metaKey: true, ctrlKey: false, altKey: false, shiftKey: true })).toBe(false)
    expect(isSaveShortcut({ key: 's', metaKey: false, ctrlKey: true, altKey: true, shiftKey: false })).toBe(false)
    expect(isSaveShortcut({ key: 's', metaKey: true, ctrlKey: true, altKey: false, shiftKey: false })).toBe(false)
    expect(isSaveShortcut({ key: 's', metaKey: false, ctrlKey: false, altKey: false, shiftKey: false })).toBe(false)
    expect(isSaveShortcut({ key: 'k', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false })).toBe(false)
  })

  test('DocumentPresence shows visible saving text during manualSaving and reverts to saved afterwards', async () => {
    const previousLanguage = i18n.language
    await loadLocale('zh-Hans-CN')
    await i18n.changeLanguage('zh-Hans-CN')
    try {
      const presence = new DocumentPresenceModel()
      presence.setConnection('connected')

      const backgroundPending = renderToStaticMarkup(<DocumentPresence model={presence} pending={true} error={false} />)
      expect(backgroundPending).toContain('data-sync-status="saving"')
      expect(backgroundPending).toContain('<span class="sr-only">保存中…</span>')

      const manualSavingMarkup = renderToStaticMarkup(
        <DocumentPresence model={presence} pending={false} error={false} manualSaving={true} />
      )
      expect(manualSavingMarkup).toContain('data-sync-status="saving"')
      expect(manualSavingMarkup).toContain('<span>保存中…</span>')
      expect(manualSavingMarkup).not.toContain('sr-only')

      const settledMarkup = renderToStaticMarkup(
        <DocumentPresence model={presence} pending={false} error={false} manualSaving={false} />
      )
      expect(settledMarkup).toContain('data-sync-status="saved"')
      expect(settledMarkup).toContain('<span class="sr-only">已保存</span>')
    } finally {
      await i18n.changeLanguage(previousLanguage || 'en-US')
    }
  })
})
