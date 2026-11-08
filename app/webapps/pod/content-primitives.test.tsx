import { t } from 'i18next'
import { beforeAll, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { ContentLoading, ContentSkeleton, InlineLoading } from './content-primitives'

beforeAll(() => loadLocale('en-US'))

const skeletons = (html: string) => html.match(/data-slot="skeleton"/g)?.length ?? 0

test('a skeleton announces its label to screen readers and draws the shape of the loading content', () => {
  const list = renderToStaticMarkup(<ContentSkeleton variant="list" rows={3} label="Loading tables…" />)
  expect(list).toContain('role="status"')
  expect(list).toContain('<span class="sr-only">Loading tables…</span>')
  expect(skeletons(list)).toBe(3)

  // A page has a title above its five body lines; a body whose title is already shown draws only the lines.
  expect(skeletons(renderToStaticMarkup(<ContentSkeleton variant="page" />))).toBe(6)
  expect(skeletons(renderToStaticMarkup(<ContentSkeleton variant="text" />))).toBe(5)
  // A table has a header above its rows.
  expect(skeletons(renderToStaticMarkup(<ContentSkeleton variant="table" rows={4} />))).toBe(5)
  expect(skeletons(renderToStaticMarkup(<ContentSkeleton variant="block" className="h-24" />))).toBe(1)
})

test('every loading status falls back to the generic label and appears at once only when asked', () => {
  const generic = t('pod.content.loading')
  for (const html of [
    renderToStaticMarkup(<ContentLoading />),
    renderToStaticMarkup(<ContentSkeleton variant="list" />),
    renderToStaticMarkup(<InlineLoading />)
  ]) {
    expect(html).toContain(generic)
    expect(html).toContain('pod-loading')
    expect(html).not.toContain('data-immediate')
  }
  expect(renderToStaticMarkup(<ContentLoading immediate />)).toContain('data-immediate="true"')
  expect(renderToStaticMarkup(<InlineLoading label="Uploading…" immediate />)).toContain('data-immediate="true"')
})
