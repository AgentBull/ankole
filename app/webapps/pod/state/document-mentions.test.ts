import { QueryClient } from '@tanstack/react-query'
import { describe, expect, test } from 'bun:test'
import type { MentionsResolveInput, MentionsResolveResponse } from '../content-api'
import { MentionStore, matchPodPageUrl, mentionPlainText, mentionStore, readPageMention } from './document-mentions'
import { pageMetadata } from './page-metadata'

describe('MentionStore and internal Pod URL matching', () => {
  test('Guest navigation resolves the same Principal separately in each Page context, in either order', async () => {
    for (const order of [
      ['unrelated', 'contributor-page'],
      ['contributor-page', 'unrelated']
    ]) {
      const calls: MentionsResolveInput[] = []
      const store = new MentionStore(async input => {
        calls.push(input)
        return {
          space_name: 'Space',
          pages: [],
          principals: [
            { principal_uid: 'usr_author', access: input.context_page_id === 'contributor-page' ? 'ok' : 'restricted' }
          ]
        }
      })
      for (const context of order) {
        const stop = store.observePrincipal('usr_author', context)
        await Bun.sleep(0)
        expect(store.principalSignal('usr_author', context).value?.access).toBe(
          context === 'contributor-page' ? 'ok' : 'restricted'
        )
        stop()
      }
      expect(calls.map(call => call.context_page_id)).toEqual(order)
    }
  })

  test('simultaneous context requests and candidate priming cannot overwrite another Page identity card', async () => {
    const pending = new Map<string, ReturnType<typeof Promise.withResolvers<MentionsResolveResponse>>>()
    const store = new MentionStore(input => {
      const request = Promise.withResolvers<MentionsResolveResponse>()
      pending.set(input.context_page_id!, request)
      return request.promise
    })
    const stopA = store.observePrincipal('usr_author', 'page-A')
    const stopB = store.observePrincipal('usr_author', 'page-B')
    await Bun.sleep(0)
    expect([...pending.keys()]).toEqual(['page-A', 'page-B'])
    pending.get('page-B')!.resolve({
      space_name: 'Space',
      pages: [],
      principals: [{ principal_uid: 'usr_author', access: 'ok', name: 'Author' }]
    })
    pending
      .get('page-A')!
      .resolve({ space_name: 'Space', pages: [], principals: [{ principal_uid: 'usr_author', access: 'restricted' }] })
    await Bun.sleep(0)
    store.primeCandidates(
      {
        space_name: 'Space',
        pages: [],
        principals: [{ principal_uid: 'usr_author', kind: 'human', name: 'Author' }],
        ranking: [],
        total_all_matches: 1
      },
      'page-B'
    )
    expect(store.peekPrincipal('usr_author', 'page-A')?.access).toBe('restricted')
    expect(store.peekPrincipal('usr_author', 'page-B')?.name).toBe('Author')
    stopA()
    store.revalidateObserved()
    pending.clear()
    await Bun.sleep(0)
    expect([...pending.keys()]).toEqual(['page-B'])
    pending
      .get('page-B')!
      .resolve({ space_name: 'Space', pages: [], principals: [{ principal_uid: 'usr_author', access: 'restricted' }] })
    await Bun.sleep(0)
    expect(store.peekPrincipal('usr_author', 'page-B')?.access).toBe('restricted')
    stopB()
  })

  test('matchPodPageUrl converts bare current-origin short and canonical Pod page URLs while rejecting external or parameterized URLs', () => {
    const id = '00112233-4455-6677-8899-aabbccddeeff'
    const short = 'ABEiM0RVZneImaq7zN3u_w'
    const origin = 'https://pod.example.com'

    expect(matchPodPageUrl(`https://pod.example.com/pages/${short}`, origin)).toBe(id)
    expect(matchPodPageUrl(`https://pod.example.com/pages/${id}/`, origin)).toBe(id)
    expect(matchPodPageUrl(`  https://pod.example.com/pages/${short}  `, origin)).toBe(id)

    expect(matchPodPageUrl(`https://other.example.com/pages/${short}`, origin)).toBeNull()
    expect(matchPodPageUrl(`https://pod.example.com/pages/${short}?chat=new`, origin)).toBeNull()
    expect(matchPodPageUrl(`https://pod.example.com/pages/${short}#section`, origin)).toBeNull()
    expect(matchPodPageUrl(`https://pod.example.com/conversations/${short}`, origin)).toBeNull()
    expect(matchPodPageUrl('https://pod.example.com/pages/not-a-valid-uuid', origin)).toBeNull()
  })

  test('MentionStore coalesces synchronous page and principal observations into a single resolve batch and revalidates access', async () => {
    const calls: MentionsResolveInput[] = []
    let secretAccessible = false
    const pageA = '00112233-4455-6677-8899-aabbccddeeff'
    const pageB = '11111111-2222-3333-4444-555555555555'
    const userU = 'usr_boris001'
    const ctxPage = '99999999-8888-7777-6666-555555555555'

    const store = new MentionStore(async (input): Promise<MentionsResolveResponse> => {
      calls.push(input)
      return {
        space_name: 'Engineering',
        pages: (input.page_ids ?? []).map(id =>
          id === pageA
            ? {
                id,
                access: 'ok',
                type: 'doc',
                title: 'Architecture Spec',
                icon: '📐',
                ancestors: ['Specs'],
                excerpt: 'System boundaries and contracts.',
                updated_at: '2026-10-29T12:00:00Z'
              }
            : secretAccessible
              ? {
                  id,
                  access: 'ok',
                  type: 'doc',
                  title: 'Confidential Roadmap',
                  icon: '🔒',
                  ancestors: [],
                  excerpt: 'Granted access.',
                  updated_at: '2026-10-29T12:00:00Z'
                }
              : {
                  id,
                  access: 'restricted'
                }
        ),
        principals: (input.principal_uids ?? []).map(uid => ({
          principal_uid: uid,
          access: 'ok',
          kind: 'human',
          membership: 'member',
          name: 'Boris Ding',
          email: 'boris@agentbull.com',
          job_title: 'Architect'
        }))
      }
    })

    const unobserveA = store.observePage(pageA, ctxPage)
    const unobserveB = store.observePage(pageB, ctxPage)
    const unobserveU = store.observePrincipal(userU, ctxPage)

    expect(store.pageSignal(pageA).value).toBeUndefined()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(calls).toHaveLength(1)
    expect(calls[0]).toEqual({
      page_ids: [pageA, pageB],
      principal_uids: [userU],
      context_page_id: ctxPage
    })
    expect(store.spaceName.value).toBe('Engineering')
    expect(store.pageSignal(pageA).value?.title).toBe('Architecture Spec')
    expect(store.pageSignal(pageB).value).toEqual({ id: pageB, access: 'restricted' })
    expect(store.principalSignal(userU, ctxPage).value?.name).toBe('Boris Ding')

    // Revalidating observed mentions refreshes access after a permission grant or revocation.
    unobserveA()
    secretAccessible = true
    store.revalidateObserved()
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(calls).toHaveLength(2)
    expect(calls[1]).toEqual({
      page_ids: [pageB],
      principal_uids: [userU],
      context_page_id: ctxPage
    })
    expect(store.pageSignal(pageB).value?.access).toBe('ok')
    expect(store.pageSignal(pageB).value?.title).toBe('Confidential Roadmap')

    unobserveB()
    unobserveU()
  })

  test('mentionPlainText and readPageMention project authoritative pageMetadata renames while gating restricted pages', () => {
    const client = new QueryClient()
    const store = mentionStore(client)
    const meta = pageMetadata(client)
    const pageID = '22222222-3333-4444-8555-666666666666'

    store.primeCandidates({
      space_name: 'Product',
      total_all_matches: 1,
      pages: [
        {
          id: pageID,
          type: 'doc',
          title: '改名前',
          icon: '📄',
          ancestors: [],
          updated_at: '2026-10-30T00:00:00Z'
        }
      ],
      principals: [],
      ranking: [{ kind: 'page', id: pageID }]
    })
    meta.update({ id: pageID, title: '改名前', icon: '📄' })
    expect(mentionPlainText(client, { page: pageID })).toBe('改名前')

    // Local rename updates shared pageMetadata; clipboard text and readPageMention reflect it immediately.
    meta.update({ id: pageID, title: '改名后', icon: '🚀' })
    expect(mentionPlainText(client, { page: pageID })).toBe('改名后')
    expect(readPageMention(client, pageID)?.icon).toBe('🚀')

    // Stale candidate snapshot cannot overwrite the newer pageMetadata write.
    store.primeCandidates({
      space_name: 'Product',
      total_all_matches: 1,
      pages: [
        {
          id: pageID,
          type: 'doc',
          title: '改名前',
          icon: '📄',
          ancestors: [],
          updated_at: '2026-10-30T00:00:00Z'
        }
      ],
      principals: [],
      ranking: [{ kind: 'page', id: pageID }]
    })
    expect(mentionPlainText(client, { page: pageID })).toBe('改名后')

    // Restricted access strictly blocks projection from pageMetadata.
    ;(store.pageSignal(pageID) as { value: unknown }).value = { id: pageID, access: 'restricted' }
    expect(readPageMention(client, pageID)).toEqual({ id: pageID, access: 'restricted' })
    expect(mentionPlainText(client, { page: pageID })).not.toContain('改名后')

    meta.dispose()
  })
})
