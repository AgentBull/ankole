import { z } from 'zod'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { rpcMethods, type BrainRPCRequester } from '../../lanes/rpc_lane'
import { lazySkillNameFromSlug, lazySkillSlugPrefix, type SkillLoader } from '../../skills/skill-loader'

export interface CreateBrainToolsOptions {
  requestBrainRPC: BrainRPCRequester
  skillLoader?: SkillLoader
}

type BrainToolDetails = JSONObject

// Fact kinds use the closed Brain whitelist; take kinds carry judgments and
// predictions. The control plane routes the two families to different writers.
const FactKinds = ['event', 'preference', 'commitment', 'belief', 'fact'] as const
const TakeKinds = ['take', 'bet', 'hunch'] as const

const AudienceScopePattern = /^(world|group:.+|principal:.+)$/

// Confidence and weight live on a 0.05 grid, and the control plane rejects a
// value off it. Enforcing the same rule here turns a wasted RPC round trip into
// an immediate, self-explaining tool error.
const GridValue = z.number().min(0).max(1).multipleOf(0.05)

// `since`/`until` mirror the control plane's parse: a full ISO 8601 instant
// with an offset, or a plain ISO date that reads as midnight UTC. An
// unparseable value is an error there, never a silently absent bound.
const ISOInstantOrDate = z.union([z.iso.datetime({ offset: true }), z.iso.date()])

const RememberParams = z
  .object({
    claim: z
      .string()
      .min(1)
      .max(2_000)
      .describe('One atomic assertion. Split a compound statement into separate remember calls.'),
    kind: z
      .enum([...FactKinds, ...TakeKinds])
      .describe(
        "The claim kind. Fact kinds record observations: 'event', 'preference', 'commitment', 'belief', 'fact'. Take kinds record judgments and predictions: 'take', 'bet', 'hunch'."
      ),
    scope: z
      .string()
      .regex(AudienceScopePattern, "scope must be 'world', 'group:<name>', or 'principal:<uid>'")
      .optional()
      .describe(
        "Omitted scope binds the claim to this conversation's audience (DM asker, or the group's member Group). Set scope explicitly when the fact should reach a different audience: consult ConfidentialityPolicy.md and select the widest scope that does not break a known confidentiality requirement."
      ),
    holder: z
      .string()
      .min(1)
      .optional()
      .describe(
        'Canonical page slug of who HOLDS this judgment, not who it is about. Defaults to you, the current agent.'
      ),
    entity: z
      .string()
      .min(1)
      .optional()
      .describe(
        'Page slug or name of an existing entity page to attach the claim to. A name that does not resolve files the claim to the current channel instead; the result reports the parent it landed on.'
      ),
    notability: z.enum(['high', 'medium', 'low']).optional().describe('Fact notability. Defaults to medium.'),
    confidence: GridValue.optional().describe(
      'For fact kinds: certainty that the fact is correct, 0..1 in 0.05 steps. Defaults to 0.75. A fact the subject reports about themselves caps at 0.75 without independent support.'
    ),
    weight: GridValue.optional().describe(
      'For take kinds: how strongly the holder holds the judgment, 0..1 in 0.05 steps. Defaults to 0.6. Your own adoption of a relayed judgment caps at 0.55.'
    ),
    until_date: z.iso
      .date()
      .optional()
      .describe('For take kinds only: the ISO date by which the judgment or prediction can be resolved.'),
    context: z
      .string()
      .max(2_000)
      .optional()
      .describe(
        'Necessary context that explains the fact; not a second claim. Applies to fact kinds only and is ignored for take kinds.'
      ),
    provenance: z.string().min(1).describe('Quote or close paraphrase of the source of this claim.')
  })
  .superRefine((params, context) => {
    if (params.until_date && !(TakeKinds as readonly string[]).includes(params.kind)) {
      context.addIssue({
        code: 'custom',
        path: ['until_date'],
        message: 'until_date is only valid for take, bet, or hunch claims'
      })
    }
  })

const LearnSourceParams = z.object({
  url: z
    .string()
    .min(1)
    .max(2_000)
    .regex(/^https?:\/\//, "url must start with 'http://' or 'https://'")
    .describe('Public web address of the material to learn.'),
  scope: z
    .string()
    .regex(AudienceScopePattern, "scope must be 'world', 'group:<name>', or 'principal:<uid>'")
    .optional()
    .describe(
      "Audience scope of the learned knowledge. Defaults to this conversation's scope. Pass 'world' only when the material is public and the requester wants the whole deployment to know it."
    )
})

const RecallParams = z.object({
  query: z.string().min(1).describe('What to search for.'),
  entity: z
    .string()
    .min(1)
    .optional()
    .describe('Page slug or name that narrows the search to one entity and its relation neighborhood.'),
  budget_tokens: z
    .number()
    .int()
    .positive()
    .max(12_000)
    .optional()
    .describe('Token budget for the result. Defaults to 4000.')
})

const GetPageParams = z.object({
  reference: z.string().min(1).describe('Page slug or natural-language name of the page to read.')
})

const ForgetParams = z
  .object({
    claim_id: z.string().min(1).optional().describe('The claim to expire.'),
    slug: z.string().min(1).optional().describe('The page to soft-delete.'),
    reason: z.string().min(1).describe('Why this memory must go. Recorded in the audit provenance.')
  })
  .superRefine((params, context) => {
    if (Boolean(params.claim_id) === Boolean(params.slug)) {
      context.addIssue({ code: 'custom', path: ['claim_id'], message: 'give exactly one of claim_id or slug' })
    }
  })

const EntityParams = z.object({
  name: z.string().min(1).describe('Page slug or natural-language name of the entity.')
})

const WhoknowsParams = z.object({
  topic: z.string().min(1).describe('The topic to find experts for.'),
  limit: z.number().int().positive().max(20).optional().describe('Maximum number of experts. Defaults to 5.')
})

const SynthesizeParams = z.object({
  question: z.string().min(1).describe('The question to answer from stored memories.')
})

const DeltaParams = z.object({
  entity: z.string().min(1).optional().describe('Page slug or name that bounds the report to one entity.'),
  since: ISOInstantOrDate.optional().describe('ISO 8601 date or datetime start of the change window.'),
  until: ISOInstantOrDate.optional().describe('ISO 8601 date or datetime end of the change window.')
})

/**
 * Creates the Brain memory tools. Registration is conditional on the
 * `brain.enabled` AppConfigure key, resolved once per turn by the caller.
 * Zod field names pass through the wire unchanged: they are the
 * control-plane BrainBroker param keys.
 */
export function createBrainTools(opts: CreateBrainToolsOptions): WorkerAgentTool[] {
  return [
    createRememberTool(opts),
    createLearnSourceTool(opts),
    createRecallTool(opts),
    createGetPageTool(opts),
    createForgetTool(opts),
    createEntityTool(opts),
    createWhoknowsTool(opts),
    createSynthesizeTool(opts),
    createDeltaTool(opts)
  ]
}

/**
 * Creates the read-only Brain subset offered to Background Agent Jobs:
 * `recall` and `get_page` let a Job reuse instance knowledge instead of
 * re-researching it. Jobs get no Brain write tools; their findings enter
 * memory through the owning main session.
 */
export function createBrainJobTools(opts: CreateBrainToolsOptions): WorkerAgentTool[] {
  return [createRecallTool(opts), createGetPageTool(opts)]
}

function createRememberTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof RememberParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'remember',
    description: [
      'Write one durable memory claim to the shared Brain.',
      'Use it for information with long-term value: facts, preferences, commitments, beliefs, events, and your own takes, bets, or hunches. Do not store small talk or transient task detail.',
      'Consult ConfidentialityPolicy.md when you choose scope. Omit scope to use the conversation audience; set it explicitly when the fact should reach a different audience. When one input contains parts with different disclosure ranges, split it and call remember once for each part with its own scope.',
      "holder names who HOLDS the judgment, not who the claim is about: when a person states an opinion about someone else, the holder is that person. Relaying someone's judgment keeps their holder; your own endorsement of it is a separate take.",
      'Use multiples of 0.05 for confidence and weight.',
      'The write persists immediately; a later failure or retry of this turn does not revert it.'
    ].join('\n'),
    schema: RememberParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_remember' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainRemember, params))
    }
  })
}

function createLearnSourceTool(
  opts: CreateBrainToolsOptions
): WorkerAgentTool<typeof LearnSourceParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'learn_source',
    description:
      'Register one web url as a Brain learning source and start its learning run in the background. Consult the brain-learning skill for source routing and scope judgment before first use.',
    schema: LearnSourceParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_learn_source' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainLearnSource, params))
    }
  })
}

function createRecallTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof RecallParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'recall',
    description: [
      'Search the Brain memory for stored knowledge that matches a query.',
      'Returns structured current facts and takes first, then page passages, inside the token budget.',
      'Give entity to narrow the search to one entity and its relation neighborhood.'
    ].join('\n'),
    schema: RecallParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_recall' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      const details = await opts.requestBrainRPC(rpcMethods.brainRecall, params)
      return jsonToolResult(details, {
        textPrefix:
          opts.skillLoader && containsLazySkillSlug(details)
            ? 'Use skill_view to load lazyload-agent-skills/ results.\n'
            : ''
      })
    }
  })
}

function createGetPageTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof GetPageParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'get_page',
    description:
      'Read one full memory page by slug or by natural-language name. Returns the page body with its current facts, timeline, and links, cut to what you may see. An ambiguous reference returns candidates instead of a guess.',
    schema: GetPageParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_page_read' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      const exactSkillName = opts.skillLoader ? lazySkillNameFromSlug(params.reference) : undefined
      if (exactSkillName) return await delegatedSkillResult(exactSkillName, opts)

      const details = await opts.requestBrainRPC(rpcMethods.brainGetPage, params)
      const resolvedSkillName = opts.skillLoader ? lazySkillNameFromPage(details) : undefined
      return resolvedSkillName ? await delegatedSkillResult(resolvedSkillName, opts) : jsonToolResult(details)
    }
  })
}

async function delegatedSkillResult(
  name: string,
  opts: CreateBrainToolsOptions
): Promise<AgentToolResult<BrainToolDetails>> {
  if (!opts.skillLoader) throw new Error('get_page requires skill_view to load a Skill discovery record')
  const loaded = await opts.skillLoader.load({ name })
  const loadedText = loaded.content.flatMap(part => (part.type === 'text' ? [part.text] : [])).join('\n')
  return {
    content: [
      {
        type: 'text',
        text: `This is a Skill discovery record; get_page delegated to skill_view("${name}") and returned the loaded Skill.\n${loadedText}`
      }
    ],
    details: {
      kind: 'skill',
      name,
      path: loaded.details.path,
      loaded_via: 'skill_view'
    }
  }
}

function lazySkillNameFromPage(details: JSONObject): string | undefined {
  const page = details.page
  if (!page || typeof page !== 'object' || Array.isArray(page)) return undefined
  const slug = (page as JSONObject).slug
  return typeof slug === 'string' ? lazySkillNameFromSlug(slug) : undefined
}

function containsLazySkillSlug(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsLazySkillSlug)
  if (!value || typeof value !== 'object') return false
  return Object.entries(value).some(([key, child]) =>
    (key === 'slug' || key === 'object_slug') && typeof child === 'string'
      ? child.startsWith(lazySkillSlugPrefix)
      : containsLazySkillSlug(child)
  )
}

function createForgetTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof ForgetParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'forget',
    description:
      'Remove one memory from recall. Give exactly one target: claim_id expires one claim; slug soft-deletes one page. The required reason enters the audit provenance.',
    schema: ForgetParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_forget' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainForget, params))
    }
  })
}

function createEntityTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof EntityParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'entity',
    description:
      'Read the entity card of one named entity: title, type, aliases, selected current facts, relations, and backlink count.',
    schema: EntityParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_entity' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainEntity, params))
    }
  })
}

function createWhoknowsTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof WhoknowsParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'whoknows',
    description:
      'Rank people and agents by what they hold about one topic. Use it to answer who in the organization knows a subject.',
    schema: WhoknowsParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_whoknows' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainWhoknows, params))
    }
  })
}

function createSynthesizeTool(
  opts: CreateBrainToolsOptions
): WorkerAgentTool<typeof SynthesizeParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'synthesize',
    description: [
      'Synthesize stored memories into a durable analysis page that answers one question, and return that page.',
      'This runs a model over recalled evidence and is expensive: use it sparingly, only when recall and get_page cannot answer.',
      'The page takes the narrowest audience scope of its evidence, so a conclusion never reaches more people than the facts behind it. The result reports that scope and how many pieces of evidence the page could not carry.'
    ].join('\n'),
    schema: SynthesizeParams,
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_synthesize' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainSynthesize, params))
    }
  })
}

function createDeltaTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof DeltaParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'delta',
    description:
      'Report what changed in memory: new, superseded, and expired claims and timeline events. Bound the report with entity, since, and until.',
    schema: DeltaParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.memory_delta' }),
    async execute(_toolCallID, params): Promise<AgentToolResult<BrainToolDetails>> {
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainDelta, params))
    }
  })
}
