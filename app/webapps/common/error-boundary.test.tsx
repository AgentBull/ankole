import { t } from 'i18next'
import { beforeAll, describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { ErrorFallback } from './error-boundary'
import { loadLocale } from './i18n'

beforeAll(() => loadLocale('en-US'))

describe('ErrorFallback', () => {
  test('inline variant exposes a copy diagnostic control alongside retry when diagnostic detail exists', () => {
    const html = renderToStaticMarkup(
      <ErrorFallback variant="inline" label="Comments" error={new Error('Unexpected token')} reset={() => {}} />
    )

    expect(html).toContain('data-error-boundary="inline"')
    expect(html).toContain(`aria-label="${t('common.copy_diagnostic')}"`)
    expect(html).toContain(t('common.retry'))
  })

  test('inline variant omits copy diagnostic when error carries no detail', () => {
    const html = renderToStaticMarkup(<ErrorFallback variant="inline" error={null} reset={() => {}} />)

    expect(html).toContain('data-error-boundary="inline"')
    expect(html).not.toContain(`aria-label="${t('common.copy_diagnostic')}"`)
    expect(html).toContain(t('common.retry'))
  })
})
