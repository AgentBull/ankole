import { z } from 'zod'
import type { JsonObject as JSONObject } from '@agentbull/active-support'
import { defineWorkerTool, type AgentToolResult, type WorkerAgentTool } from '../../core'
import { jsonToolResult } from '../../core/tool-result'
import { rpcMethods, type BrainRPCRequester } from '../../lanes/rpc_lane'

export interface CreateBrainToolsOptions {
  requestBrainRPC: BrainRPCRequester
}

type BrainToolDetails = JSONObject

// Fact kinds use the closed Brain whitelist; take kinds carry judgments and
// predictions. The control plane routes the two families to different writers.
const FactKinds = ['event', 'preference', 'commitment', 'belief', 'fact'] as const
const TakeKinds = ['take', 'bet', 'hunch'] as const

const AudienceScopePattern = /^(world|group:.+|principal:.+)$/

const RememberParams = z.object({
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
    .describe(
      "Audience scope: 'world', 'group:<name>', or 'principal:<uid>'. Consult the ConfidentialityPolicy.md guidance and select the widest scope that does not break a known confidentiality requirement."
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
  confidence: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      'For fact kinds: certainty that the fact is correct, 0..1 in 0.05 steps. Defaults to 0.75. A fact the subject reports about themselves caps at 0.75 without independent support.'
    ),
  weight: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      'For take kinds: how strongly the holder holds the judgment, 0..1 in 0.05 steps. Defaults to 0.6. Your own adoption of a relayed judgment caps at 0.55.'
    ),
  context: z
    .string()
    .max(2_000)
    .optional()
    .describe(
      'Necessary context that explains the fact; not a second claim. Applies to fact kinds only and is ignored for take kinds.'
    ),
  provenance: z.string().min(1).describe('Quote or close paraphrase of the source of this claim.')
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
  since: z.string().min(1).optional().describe('ISO 8601 date or datetime start of the change window.'),
  until: z.string().min(1).optional().describe('ISO 8601 date or datetime end of the change window.')
})

/**
 * Creates the Brain memory tools. Registration is conditional on the
 * `brain.enabled` AppConfigure key, resolved once per turn by the caller.
 * Zod field names pass through the wire unchanged: they are the
 * control-plane BrainBroker param keys.
 */
export function createBrainTools(opts: CreateBrainToolsOptions): WorkerAgentTool<any>[] {
  return [
    createRememberTool(opts),
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
export function createBrainJobTools(opts: CreateBrainToolsOptions): WorkerAgentTool<any>[] {
  return [createRecallTool(opts), createGetPageTool(opts)]
}

function createRememberTool(opts: CreateBrainToolsOptions): WorkerAgentTool<typeof RememberParams, BrainToolDetails> {
  return defineWorkerTool({
    name: 'remember',
    description: [
      'Write one durable memory claim to the shared Brain.',
      'Use it for information with long-term value: facts, preferences, commitments, beliefs, events, and your own takes, bets, or hunches. Do not store small talk or transient task detail.',
      'Consult the ConfidentialityPolicy.md guidance when you choose scope. When one input contains parts with different disclosure ranges, split it and call remember once for each part with its own scope.',
      'holder names who HOLDS the judgment, not who the claim is about: when a person states an opinion about someone else, the holder is that person.',
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
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainRecall, params))
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
      return jsonToolResult(await opts.requestBrainRPC(rpcMethods.brainGetPage, params))
    }
  })
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
