import { t } from 'i18next'
import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { ContentLoading, ContentSkeleton, InlineLoading } from './content-primitives'

beforeAll(() => loadLocale('en-US'))

test('loading states expose the generic or caller-supplied label', () => {
  const generic = t('pod.content.loading')
  for (const html of [
    renderToStaticMarkup(<ContentLoading />),
    renderToStaticMarkup(<ContentSkeleton variant="list" />),
    renderToStaticMarkup(<InlineLoading />)
  ]) {
    expect(html).toContain(generic)
    expect(html).toContain('role="status"')
  }
  const labeled = renderToStaticMarkup(<ContentSkeleton variant="list" label="Loading tables…" />)
  expect(labeled).toContain('Loading tables…')
})
