import { expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { ConnectorConfigFields } from './connector-config-fields'
import { ConsoleTenantContext } from './tenant-context'

test('connection selectors render inside a Console tenant section and scope both queries to it', () => {
  const tenant = { id: 'tenant-a', display_name: 'Tenant A', slug: 'tenant-a', first: false }
  const client = new QueryClient()

  try {
    renderToStaticMarkup(
      <QueryClientProvider client={client}>
        <ConsoleTenantContext value={tenant}>
          <ConnectorConfigFields
            pluginId="lark-adapter"
            config={{}}
            fields={[]}
            locale="en-US"
            onChange={() => {}}
            onConnectionChange={() => {}}
          />
        </ConsoleTenantContext>
      </QueryClientProvider>
    )

    const requests = client
      .getQueryCache()
      .getAll()
      .map(query => query.queryKey[0])
    expect(requests).toHaveLength(2)
    for (const request of requests) {
      expect(request).toEqual(expect.objectContaining({ headers: { 'x-ankole-tenant': tenant.id } }))
    }
  } finally {
    client.clear()
  }
})
