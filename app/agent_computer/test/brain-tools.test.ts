import { describe, expect, it } from 'bun:test'
import { create } from '@bufbuild/protobuf'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { jsonBytes } from '../src/fabric/envelope_proto'
import { JSONPassthroughResponseSchema } from '../src/fabric/generated/ankole/runtime_fabric/v1/rpc_pb'
import type { ActorTurnRef } from '../src/lanes/actor_lane'
import { brainRPCRequester, type RPCRequester } from '../src/lanes/rpc_lane'
import { createBrainJobTools, createBrainTools } from '../src/tools/brain/brain-tools'
import type { SkillLoader } from '../src/skills/skill-loader'

const turn: ActorTurnRef = {
  actor: { agent_uid: 'agent-brain', session_id: 'session-1' },
  activation_uid: 'activation-1',
  actor_epoch: 1,
  actor_event_id: 'event-1',
  revision: 1
}

function brainRPC(expectedMethod: string, body: JSONObject, onParams?: (params: JSONObject) => void): RPCRequester {
  return (async (method: unknown, payload: unknown, frame: unknown) => {
    expect(method).toBe(expectedMethod)
    expect(frame).toEqual({ turn })
    const request = payload as { paramsJson: Uint8Array }
    onParams?.(JSON.parse(new TextDecoder().decode(request.paramsJson)) as JSONObject)
    return create(JSONPassthroughResponseSchema, { bodyJson: jsonBytes(body) })
  }) as RPCRequester
}

function brainTools(rpc: RPCRequester, skillLoader?: SkillLoader) {
  return createBrainTools({ requestBrainRPC: brainRPCRequester(rpc, turn), skillLoader })
}

function brainTool(rpc: RPCRequester, name: string, skillLoader?: SkillLoader) {
  const tool = brainTools(rpc, skillLoader).find(candidate => candidate.name === name)
  if (!tool) throw new Error(`missing brain tool ${name}`)
  return tool
}

function brainJobTool(rpc: RPCRequester, name: string, skillLoader?: SkillLoader) {
  const tool = createBrainJobTools({ requestBrainRPC: brainRPCRequester(rpc, turn), skillLoader }).find(
    candidate => candidate.name === name
  )
  if (!tool) throw new Error(`missing Brain Job tool ${name}`)
  return tool
}

describe('@ankole/agent-computer brain tools', () => {
  it('registers the nine memory tools', () => {
    const names = brainTools(brainRPC('unused', {})).map(tool => tool.name)

    expect(names).toEqual([
      'remember',
      'learn_source',
      'recall',
      'get_page',
      'forget',
      'entity',
      'whoknows',
      'synthesize',
      'delta'
    ])
  })

  it('validates learn_source urls and scope', () => {
    const rpc = brainRPC('unused', {})
    const tool = brainTool(rpc, 'learn_source')

    expect(tool.schema.safeParse({ url: 'https://example.com/paper' }).success).toBe(true)
    expect(tool.schema.safeParse({ url: 'https://example.com/paper', scope: 'world' }).success).toBe(true)
    expect(tool.schema.safeParse({ url: 'ftp://example.com/file' }).success).toBe(false)
    expect(tool.schema.safeParse({ url: 'example.com/no-protocol' }).success).toBe(false)
    expect(tool.schema.safeParse({ url: 'https://example.com', scope: 'company:x' }).success).toBe(false)
  })

  it('validates remember scope, kinds, and required provenance', () => {
    const rpc = brainRPC('unused', {})
    const tool = brainTool(rpc, 'remember')
    const base = {
      claim: 'Ding prefers concise replies.',
      kind: 'preference',
      provenance: 'Ding said so on 2026-08-25.'
    }

    expect(tool.schema.safeParse({ ...base, scope: 'world' }).success).toBe(true)
    expect(tool.schema.safeParse({ ...base, scope: 'group:sales' }).success).toBe(true)
    expect(tool.schema.safeParse({ ...base, scope: 'principal:user-1' }).success).toBe(true)
    expect(tool.schema.safeParse({ ...base, scope: 'company:sales' }).success).toBe(false)
    expect(tool.schema.safeParse({ ...base, scope: 'group:' }).success).toBe(false)
    expect(tool.schema.safeParse({ ...base, kind: 'hunch', scope: 'world', weight: 0.6 }).success).toBe(true)
    expect(tool.schema.safeParse({ ...base, kind: 'rumor', scope: 'world' }).success).toBe(false)
    expect(tool.schema.safeParse({ claim: 'x', kind: 'fact', scope: 'world' }).success).toBe(false)
    expect(tool.schema.safeParse({ ...base, scope: 'world', confidence: 1.5 }).success).toBe(false)
  })

  it('sends remember params as BrainBroker JSON keys and returns the passthrough body', async () => {
    let sent: JSONObject | undefined
    const rpc = brainRPC(
      'brain.remember',
      { status: 'inserted', claim_id: 'claim-1', audience_scope: 'group:sales' },
      params => {
        sent = params
      }
    )
    const tool = brainTool(rpc, 'remember')
    const params = tool.schema.parse({
      claim: 'Acme renewed the annual contract.',
      kind: 'event',
      scope: 'group:sales',
      entity: 'companies/acme',
      notability: 'high',
      confidence: 0.9,
      provenance: 'Zhang San announced it in #sales.'
    })

    const result = await tool.execute('brain-1', params)

    expect(sent).toEqual({
      claim: 'Acme renewed the annual contract.',
      kind: 'event',
      scope: 'group:sales',
      entity: 'companies/acme',
      notability: 'high',
      confidence: 0.9,
      provenance: 'Zhang San announced it in #sales.'
    })
    expect(result.details).toEqual({ status: 'inserted', claim_id: 'claim-1', audience_scope: 'group:sales' })
    expect(JSON.parse(result.content[0]?.type === 'text' ? result.content[0].text : '')).toEqual(result.details)
  })

  it('requires exactly one forget target', () => {
    const rpc = brainRPC('unused', {})
    const tool = brainTool(rpc, 'forget')

    expect(tool.schema.safeParse({ claim_id: 'claim-1', reason: 'wrong fact' }).success).toBe(true)
    expect(tool.schema.safeParse({ slug: 'people/zhang-san', reason: 'duplicate page' }).success).toBe(true)
    expect(tool.schema.safeParse({ reason: 'no target' }).success).toBe(false)
    expect(tool.schema.safeParse({ claim_id: 'claim-1', slug: 'people/zhang-san', reason: 'both' }).success).toBe(false)
    expect(tool.schema.safeParse({ claim_id: 'claim-1' }).success).toBe(false)
  })

  it('bounds recall and whoknows numeric params', () => {
    const rpc = brainRPC('unused', {})
    const recall = brainTool(rpc, 'recall')
    const whoknows = brainTool(rpc, 'whoknows')

    expect(recall.schema.safeParse({ query: 'contract renewals' }).success).toBe(true)
    expect(recall.schema.safeParse({ query: 'contract renewals', budget_tokens: 2_000 }).success).toBe(true)
    expect(recall.schema.safeParse({ query: 'contract renewals', budget_tokens: 0 }).success).toBe(false)
    expect(recall.schema.safeParse({ query: 'contract renewals', budget_tokens: 20_000 }).success).toBe(false)
    expect(whoknows.schema.safeParse({ topic: 'vector databases', limit: 5 }).success).toBe(true)
    expect(whoknows.schema.safeParse({ topic: 'vector databases', limit: 0 }).success).toBe(false)
  })

  it('routes each read tool to its RPC method', async () => {
    const cases: Array<{ name: string; method: string; params: JSONObject }> = [
      { name: 'recall', method: 'brain.recall', params: { query: 'renewals' } },
      { name: 'get_page', method: 'brain.get_page', params: { reference: 'companies/acme' } },
      { name: 'entity', method: 'brain.entity', params: { name: 'Acme' } },
      { name: 'whoknows', method: 'brain.whoknows', params: { topic: 'pricing' } },
      { name: 'synthesize', method: 'brain.synthesize', params: { question: 'How did the Acme deal evolve?' } },
      { name: 'delta', method: 'brain.delta', params: { entity: 'companies/acme', since: '2026-08-01T00:00:00Z' } }
    ]

    for (const { name, method, params } of cases) {
      let sent: JSONObject | undefined
      const tool = brainTool(
        brainRPC(method, { ok: true }, sentParams => {
          sent = sentParams
        }),
        name
      )

      const result = await tool.execute('brain-2', tool.schema.parse(params))

      expect(sent).toEqual(params)
      expect(result.details).toEqual({ ok: true })
    }
  })

  it('adds the lazy Skill hint only when recall returns a lazy Skill slug', async () => {
    const loader = fakeSkillLoader([])
    const lazy = brainJobTool(
      brainRPC('brain.recall', {
        chunks: [{ object_slug: 'lazyload-agent-skills/voice-drafting-method', text: 'Draft by listening.' }]
      }),
      'recall',
      loader
    )
    const ordinary = brainJobTool(
      brainRPC('brain.recall', { chunks: [{ object_slug: 'concepts/voice', text: 'Voice.' }] }),
      'recall',
      loader
    )

    const lazyResult = await lazy.execute('brain-lazy', { query: 'voice drafting' })
    const ordinaryResult = await ordinary.execute('brain-ordinary', { query: 'voice drafting' })
    const lazyText = lazyResult.content[0]?.type === 'text' ? lazyResult.content[0].text : ''
    const ordinaryText = ordinaryResult.content[0]?.type === 'text' ? ordinaryResult.content[0].text : ''

    expect(lazyText).toStartWith('Use skill_view to load lazyload-agent-skills/ results.\n')
    expect(ordinaryText).not.toContain('Use skill_view')
    expect(lazyResult.details).toEqual({
      chunks: [{ object_slug: 'lazyload-agent-skills/voice-drafting-method', text: 'Draft by listening.' }]
    })
  })

  it('returns lazy Skill recall results without a skill_view hint when no loader exists', async () => {
    const details = {
      chunks: [{ object_slug: 'lazyload-agent-skills/voice-drafting-method', text: 'Draft by listening.' }]
    }
    const tool = brainJobTool(brainRPC('brain.recall', details), 'recall')

    const result = await tool.execute('brain-lazy-without-loader', { query: 'voice drafting' })
    const text = result.content[0]?.type === 'text' ? result.content[0].text : ''

    expect(text).not.toContain('Use skill_view')
    expect(result.details).toEqual(details)
  })

  it('delegates an exact lazy Skill slug without calling Brain', async () => {
    const loadedNames: string[] = []
    const loader = fakeSkillLoader(loadedNames)
    const rpc = (async () => {
      throw new Error('exact lazy Skill slug must bypass Brain get_page')
    }) as RPCRequester
    const tool = brainJobTool(rpc, 'get_page', loader)

    const result = await tool.execute('brain-lazy-page', {
      reference: 'lazyload-agent-skills/voice-drafting-method'
    })
    const text = result.content[0]?.type === 'text' ? result.content[0].text : ''

    expect(loadedNames).toEqual(['voice-drafting-method'])
    expect(text).toStartWith(
      'This is a Skill discovery record; get_page delegated to skill_view("voice-drafting-method") and returned the loaded Skill.\n'
    )
    expect(text).toContain('<external_content source="skill">')
    expect(result.details).toEqual({
      kind: 'skill',
      name: 'voice-drafting-method',
      path: 'SKILL.md',
      loaded_via: 'skill_view'
    })
  })

  it('reads an exact lazy Skill page through Brain when no loader exists', async () => {
    let sent: JSONObject | undefined
    const details = {
      page: { slug: 'lazyload-agent-skills/voice-drafting-method', title: 'Voice drafting' }
    }
    const tool = brainJobTool(
      brainRPC('brain.get_page', details, params => {
        sent = params
      }),
      'get_page'
    )

    const result = await tool.execute('brain-lazy-page-without-loader', {
      reference: 'lazyload-agent-skills/voice-drafting-method'
    })

    expect(sent).toEqual({ reference: 'lazyload-agent-skills/voice-drafting-method' })
    expect(result.details).toEqual(details)
  })

  it('preserves Brain ambiguity and delegates only a resolved lazy Skill page', async () => {
    const ambiguousLoads: string[] = []
    const ambiguous = brainJobTool(
      brainRPC('brain.get_page', {
        candidates: [
          { slug: 'lazyload-agent-skills/voice-drafting-method', title: 'Voice drafting' },
          { slug: 'concepts/voice-drafting', title: 'Voice drafting concept' }
        ]
      }),
      'get_page',
      fakeSkillLoader(ambiguousLoads)
    )
    const resolvedLoads: string[] = []
    const resolved = brainJobTool(
      brainRPC('brain.get_page', {
        page: { slug: 'lazyload-agent-skills/voice-drafting-method', title: 'Voice drafting' }
      }),
      'get_page',
      fakeSkillLoader(resolvedLoads)
    )

    const ambiguousResult = await ambiguous.execute('brain-ambiguous', { reference: 'voice drafting' })
    const resolvedResult = await resolved.execute('brain-resolved', { reference: 'voice drafting method' })

    expect(ambiguousLoads).toEqual([])
    expect(ambiguousResult.details).toHaveProperty('candidates')
    expect(resolvedLoads).toEqual(['voice-drafting-method'])
    expect(resolvedResult.details).toMatchObject({ kind: 'skill', loaded_via: 'skill_view' })
  })

  it('keeps a naturally resolved lazy Skill page as a Brain result when no loader exists', async () => {
    let sent: JSONObject | undefined
    const details = {
      page: { slug: 'lazyload-agent-skills/voice-drafting-method', title: 'Voice drafting' }
    }
    const tool = brainJobTool(
      brainRPC('brain.get_page', details, params => {
        sent = params
      }),
      'get_page'
    )

    const result = await tool.execute('brain-resolved-without-loader', {
      reference: 'voice drafting method'
    })

    expect(sent).toEqual({ reference: 'voice drafting method' })
    expect(result.details).toEqual(details)
  })
})

function fakeSkillLoader(loadedNames: string[]): SkillLoader {
  return {
    disable() {},
    async load({ name }) {
      loadedNames.push(name)
      return {
        content: [
          {
            type: 'text',
            text: `<skill name="${name}"><external_content source="skill"># Loaded</external_content></skill>`
          }
        ],
        details: { name, path: 'SKILL.md' }
      }
    }
  }
}
