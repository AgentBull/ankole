import { authenticationRef, podID } from '../common/browser-context'
import type { QueryClient } from '@tanstack/react-query'
import { pageMetadata } from './state/page-metadata'
import {
  metaSkills,
  metaSkill,
  metaAgents,
  metaAgent,
  metaAgentContracts,
  metaGlobalContracts,
  metaBrain
} from './api/generated/sdk.gen'

export * from './api/generated/sdk.gen'
export const metaKeys = {
  get all() {
    return ['pod-meta', authenticationRef() ?? '', podID() ?? ''] as const
  },
  skills: () => [...metaKeys.all, 'skills'] as const,
  skill: (slug: string) => [...metaKeys.skills(), slug] as const,
  agents: () => [...metaKeys.all, 'agents'] as const,
  agent: (uid: string) => [...metaKeys.agents(), uid] as const,
  contracts: (uid: string | null) => [...metaKeys.all, 'contracts', uid] as const,
  brain: () => [...metaKeys.all, 'brain'] as const
}
export const metaSkillsQuery = () => ({
  queryKey: metaKeys.skills(),
  queryFn: ({ signal }: { signal: AbortSignal }) => metaSkills({ signal })
})
export const metaSkillQuery = (slug: string) => ({
  queryKey: metaKeys.skill(slug),
  queryFn: ({ signal }: { signal: AbortSignal }) => metaSkill({ path: { slug }, signal })
})
export const metaAgentsQuery = () => ({
  queryKey: metaKeys.agents(),
  queryFn: ({ signal }: { signal: AbortSignal }) => metaAgents({ signal })
})
export const metaAgentQuery = (uid: string) => ({
  queryKey: metaKeys.agent(uid),
  queryFn: ({ signal }: { signal: AbortSignal }) => metaAgent({ path: { uid }, signal })
})
export const metaContractsQuery = (uid: string | null) => ({
  queryKey: metaKeys.contracts(uid),
  queryFn: ({ signal }: { signal: AbortSignal }) =>
    uid === null ? metaGlobalContracts({ signal }) : metaAgentContracts({ path: { uid }, signal })
})
export const metaBrainQuery = () => ({
  queryKey: metaKeys.brain(),
  queryFn: ({ signal, client }: { signal: AbortSignal; client: QueryClient }) =>
    pageMetadata(client).read(
      () => metaBrain({ signal }),
      result => result.nodes
    )
})
export type MetaBrainGraph = NonNullable<Awaited<ReturnType<typeof metaBrain>>>
export type MetaSkill = NonNullable<Awaited<ReturnType<typeof metaSkills>>>['skills'][number]
export type MetaAgent = NonNullable<Awaited<ReturnType<typeof metaAgents>>>['agents'][number]

export async function fileBase64(file: File): Promise<string> {
  const bytes = new Uint8Array(await file.arrayBuffer())
  let binary = ''
  for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192))
  return btoa(binary)
}
