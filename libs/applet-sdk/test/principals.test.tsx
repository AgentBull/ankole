import { describe, expect, test } from 'bun:test'
import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import {
  AppletRuntimeProvider,
  createReadDenials,
  normalizePrincipalUID,
  usePod,
  usePrincipal,
  usePrincipals
} from '../src/index'
import type { AppletRuntime, PodChatOpenOptions, PodPrincipal } from '../src/types'

function makeRuntime(
  client: QueryClient,
  principals: PodPrincipal[],
  onNavigate?: (pageID: string) => void,
  onOpenChat?: (options?: PodChatOpenOptions) => void
): AppletRuntime {
  const denials = createReadDenials(client.getQueryCache())
  const unused = async () => {
    throw new Error('Unused in principal fixture')
  }
  return {
    pageID: 'applet-demo',
    title: 'Ops Desk',
    embedded: false,
    instanceID: 'applet-demo',
    actions: ['node_view'],
    revision: 1,
    queryClient: client,
    readDenial: denials.get,
    routes: { key: () => ['applet-demo'], call: unused },
    runs: { key: () => ['applet-demo', 'run'], get: unused, subscribe: () => () => {} },
    base: {
      key: () => ['applet-demo', 'table'],
      schema: unused,
      records: unused,
      aggregate: unused,
      write: unused,
      subscribe: () => () => {}
    },
    pod: {
      request: unused,
      fileURL: target => (typeof target === 'string' ? target : target.path),
      navigateToPage: pageID => onNavigate?.(pageID),
      openChat: options => onOpenChat?.(options),
      principalsKey: ['pod-content', 'auth-1', 'pod-1', 'principals'],
      principals: async () => principals
    },
    theme: 'light',
    channel() {
      throw new Error('Unused in principal fixture')
    }
  }
}

describe('normalizePrincipalUID and usePrincipals', () => {
  test('normalizes bare UIDs, ActorRef strings, ActorRef maps, and Brain Principal slugs', () => {
    expect(normalizePrincipalUID('Maya')).toBe('maya')
    expect(normalizePrincipalUID('@ops-colleague')).toBe('ops-colleague')
    expect(normalizePrincipalUID('ankole:01950000-0000-7000-8000-000000000001:principal/Maya')).toBe('maya')
    expect(normalizePrincipalUID({ uid: 'Growth-Agent' })).toBe('growth-agent')
    expect(normalizePrincipalUID('people/maya')).toBe('maya')
    expect(normalizePrincipalUID('agents/ops-colleague')).toBe('ops-colleague')
    expect(normalizePrincipalUID('')).toBeNull()
    expect(normalizePrincipalUID(null)).toBeNull()
  })

  test('usePrincipals, usePrincipal, navigateToPage, and openChat resolve cached subjects and invoke host bridges', () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } })
    const directory: PodPrincipal[] = [
      { uid: 'maya', name: 'Maya Lin', kind: 'human' },
      { uid: 'ops-colleague', name: 'Ops Colleague', kind: 'agent', subtitle: 'Supply Chain' }
    ]
    client.setQueryData(['pod-content', 'auth-1', 'pod-1', 'principals'], directory)

    const navigations: string[] = []
    const chats: (PodChatOpenOptions | undefined)[] = []
    const runtime = makeRuntime(
      client,
      directory,
      pageID => navigations.push(pageID),
      options => chats.push(options)
    )

    function Probe() {
      const { pod } = usePod()
      const subset = usePrincipals([
        'ankole:01950000-0000-7000-8000-000000000001:principal/ops-colleague',
        { uid: 'maya' },
        'maya'
      ])
      const single = usePrincipal('agents/ops-colleague')
      pod.navigateToPage('page-sop-returns')
      pod.openChat({ quote: 'Order #1042', prompt: 'Draft refund options' })
      return createElement(
        'div',
        null,
        `${subset.principals.map(p => `${p.name}:${p.kind}`).join('|')}#${single.principal?.name ?? ''}`
      )
    }

    const html = renderToStaticMarkup(
      createElement(
        QueryClientProvider,
        { client },
        createElement(AppletRuntimeProvider, { runtime, children: createElement(Probe) })
      )
    )

    expect(html).toContain('Ops Colleague:agent|Maya Lin:human#Ops Colleague')
    expect(client.getQueryCache().getAll().length).toBe(1)
    expect(navigations).toEqual(['page-sop-returns'])
    expect(chats).toEqual([{ quote: 'Order #1042', prompt: 'Draft refund options' }])
    client.clear()
  })
})
