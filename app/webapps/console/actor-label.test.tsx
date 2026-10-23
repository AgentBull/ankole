import { describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { ActorLabel } from './actor-label'
import { getPrincipalQueryKey } from './api/v2/generated/@tanstack/react-query.gen'
import { listTenantsQueryKey } from './api/v2-site/generated/@tanstack/react-query.gen'

const authorTenant = '019a2b00-0000-7000-8000-000000000001'
const actor = { tenant_id: authorTenant, uid: 'legacy@example.com' }

function client() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  client.setQueryData(listTenantsQueryKey(), {
    data: [{ id: authorTenant, type: 'tenant', attributes: { display_name: 'Original team' } }]
  })
  return client
}

function render(client: QueryClient, reference: typeof actor | null | undefined = actor) {
  return renderToStaticMarkup(
    <QueryClientProvider client={client}>
      <ActorLabel actor={reference} />
    </QueryClientProvider>
  )
}

describe('ActorLabel', () => {
  test('shows a dash when the actor is absent', () => {
    const queryClient = client()
    expect(render(queryClient, null)).toContain('>—</span>')
    queryClient.clear()
  })
  test('uses the author tenant for its lookup independently of the active resource context', () => {
    const queryClient = client()
    queryClient.setQueryData(
      getPrincipalQueryKey({
        path: { uid: 'legacy@example.com' },
        headers: { 'x-ankole-tenant': authorTenant }
      }),
      { data: { id: 'legacy@example.com', type: 'principal', attributes: { display_name: 'Alice' } } }
    )

    expect(render(queryClient)).toContain('Original team / Alice')
  })

  test('keeps the UID readable and tenant ID available when its principal no longer exists', () => {
    const html = render(client())
    expect(html).toContain(`>${actor.uid}</span>`)
    expect(html).toContain(`title="${actor.tenant_id} / ${actor.uid}"`)
    expect(html).not.toContain('Original team /')
  })
})
