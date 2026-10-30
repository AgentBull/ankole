import { Button } from '@ankole/uikit'
import '@ankole/uikit/styles.css'
import { lazy, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AuthApp } from '../../auth/app'
import { ErrorBoundary, ErrorFallback } from '../../common/error-boundary'
import { loadLocale } from '../../common/i18n'
import { mountApp } from '../../common/mount'
import '../../common/styles.css'
import { PodSettings } from '../../pod/pod-settings'
import { PodApp } from '../../pod/app'
import '../../pod/pod.css'
import { PodSlotsContext } from '../../pod/slots'

declare global {
  interface Window {
    __bootMarker?: string
    __sidebarFailure?: boolean
  }
}

window.__bootMarker ??= crypto.randomUUID()

function SidebarFailure() {
  if (window.__sidebarFailure) throw new Error('Sidebar render failure')
  return null
}

const BrokenChallenge = lazy(async () => ({
  default: function BrokenChallengeSlot(): never {
    throw new TypeError("Cannot read properties of undefined (reading 'filter')")
  }
}))

const BrokenSettingsExtension = lazy(async () => ({
  default: function BrokenSettingsExtensionSlot(): never {
    throw new TypeError('Extension settings render failure')
  }
}))

function CrashingPanel({ fail }: { fail: boolean }) {
  if (fail) {
    const missing = undefined as unknown as { filter(predicate: () => boolean): unknown[] }
    missing.filter(() => true)
  }
  return <div data-testid="panel-healthy">Panel recovered and interactive</div>
}

function BoundaryHarness() {
  const { t, i18n } = useTranslation()
  const [failPanel, setFailPanel] = useState(true)
  const [sectionKey, setSectionKey] = useState('alpha')
  const [draft, setDraft] = useState('Unsaved architecture notes')
  const [exportedDraft, setExportedDraft] = useState<string | null>(null)
  const [showShellPreview, setShowShellPreview] = useState(false)

  return (
    <div className="grid gap-6 p-6">
      <header className="flex flex-wrap items-center gap-3 border-b border-border pb-4">
        <h1 className="text-lg font-semibold">Workspace Shell</h1>
        <Button
          type="button"
          size="xs"
          variant="outline"
          onClick={async () => {
            const next = i18n.language.startsWith('zh') ? 'en-US' : 'zh-Hans-CN'
            await loadLocale(next)
            await i18n.changeLanguage(next)
          }}>
          Toggle locale
        </Button>
        <Button type="button" size="xs" variant="outline" onClick={() => setFailPanel(value => !value)}>
          {failPanel ? 'Arm recovery' : 'Inject crash'}
        </Button>
        <Button
          type="button"
          size="xs"
          variant="outline"
          onClick={() => setSectionKey(current => (current === 'alpha' ? 'beta' : 'alpha'))}>
          Switch context
        </Button>
        <Button type="button" size="xs" variant="ghost" onClick={() => setShowShellPreview(value => !value)}>
          Toggle shell fallback
        </Button>
      </header>

      <label className="grid max-w-md gap-1 text-sm">
        <span>Draft editor</span>
        <input
          aria-label="Draft editor"
          className="rounded-control border border-border px-3 py-1.5"
          value={draft}
          onChange={event => setDraft(event.target.value)}
        />
      </label>

      {exportedDraft ? <p data-testid="exported-draft">{exportedDraft}</p> : null}

      <div data-testid="healthy-sibling">Healthy sibling remains interactive ({sectionKey})</div>

      <ErrorBoundary
        variant="panel"
        resetKeys={[sectionKey]}
        actions={
          draft.trim() ? (
            <Button type="button" size="sm" onClick={() => setExportedDraft(draft)}>
              {t('pod.content.export_draft')}
            </Button>
          ) : undefined
        }>
        <CrashingPanel fail={failPanel} />
      </ErrorBoundary>

      {showShellPreview ? (
        <ErrorFallback
          variant="shell"
          error={new TypeError('Fatal shell failure')}
          reset={() => setShowShellPreview(false)}
        />
      ) : null}
    </div>
  )
}

const params = new URLSearchParams(window.location.search)
const surface = params.get('surface')
if (surface === 'auth') {
  window.history.replaceState(null, '', '/sessions/new')
} else if (surface === 'pod-sidebar') {
  window.__sidebarFailure = true
  window.history.replaceState(null, '', '/')
}

await mountApp(
  surface === 'auth' ? (
    <AuthApp
      slots={{
        emailOtpChallenge: {
          pluginId: 'fixture-ui',
          when: 'fixture.visible',
          Component: BrokenChallenge
        }
      }}
    />
  ) : surface === 'pod-sidebar' ? (
    <PodApp
      slots={{
        accountNavigation: {
          pluginId: 'fixture-ui',
          when: 'fixture.visible',
          content: <SidebarFailure />
        }
      }}
    />
  ) : surface === 'pod-settings' ? (
    <PodSlotsContext
      value={{
        settingsTabs: [
          {
            id: 'broken-extension',
            pluginId: 'fixture-ui',
            labelKey: 'Broken extension',
            when: 'fixture.visible',
            Component: BrokenSettingsExtension
          }
        ]
      }}>
      <PodSettings />
    </PodSlotsContext>
  ) : (
    <BoundaryHarness />
  )
)
