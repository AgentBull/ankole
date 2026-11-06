import { t } from 'i18next'
import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { pageSearchQuery, type Page } from './content-api'
import { PagePicker } from './page-picker'

beforeAll(() => loadLocale('en-US'))

function page(id: string, parent_id: string | null, extra: Partial<Page> = {}): Page {
  return {
    id,
    name: id,
    parent_id,
    actions: ['node_view', 'node_edit'],
    type: 'doc',
    title: id,
    position: id,
    icon: null,
    private_owner_uid: null,
    inherit_permissions: true,
    metadata: {},
    revision: 0,
    saved_from_message_id: null,
    deleted_at: null,
    purge_started_at: null,
    is_root: parent_id === null,
    ...extra
  }
}

test('move targets name the Space, the reader’s Private, or a share as their location', () => {
  const client = new QueryClient({
    defaultOptions: { queries: { gcTime: Infinity, retry: false, staleTime: Infinity } }
  })
  client.setQueryData(
    pageSearchQuery('', { exclude_subtree_of: 'source', required_action: 'node_edit', domain: undefined }).queryKey,
    {
      pages: [
        page('space-target', 'space-root'),
        page('private-target', 'private-root'),
        page('nested-target', 'space-folder'),
        page('shared-target', 'hidden-parent')
      ],
      ancestors: [
        page('space-root', null),
        page('private-root', null, { private_owner_uid: 'reader' }),
        page('space-folder', 'space-root')
      ],
      principal_uid: 'reader',
      can_create_private: true,
      can_create_space: true
    }
  )
  const html = renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <PagePicker label="Destination" excludeSubtreeOf="source" requiredAction="node_edit" onSelect={() => {}} />
    </QueryClientProvider>
  )
  const location = (id: string) =>
    html.match(new RegExp(`${id}</span><span class="[^"]*">([^<]*)</span>`))?.[1].replaceAll('&#x27;', "'")
  expect(location('space-target')).toBe(t('pod.content.space'))
  expect(location('private-target')).toBe(t('pod.content.private'))
  expect(location('nested-target')).toBe(`${t('pod.content.space')} / space-folder`)
  expect(location('shared-target')).toBe(t('pod.content.shared_with_me'))
})
