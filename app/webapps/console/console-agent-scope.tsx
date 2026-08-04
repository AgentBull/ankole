import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { ankoleWebAgentControllerIndexOptions } from './api/generated/@tanstack/react-query.gen'

/**
 * The agent a list page is scoped to, held in `?agent=`.
 *
 * Schedules, webhook endpoints, and automation jobs are stored per agent
 * session, but a session id is an opaque partition key that the operator never
 * chose and cannot recall. These pages therefore scope to the agent and carry
 * the owning session as a row value.
 */
export function useAgentScope() {
  const [searchParams, setSearchParams] = useSearchParams()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentList = agents.data?.agents ?? []
  const agentUID = searchParams.get('agent') ?? agentList[0]?.uid ?? ''

  // Every other parameter names something inside the current agent, so a new
  // agent starts from a clean scope instead of a dangling selection.
  const selectAgent = (uid: string) =>
    setSearchParams(uid ? new URLSearchParams({ agent: uid }) : new URLSearchParams())

  return { agentUID, agents: agentList, error: agents.error, isLoading: agents.isLoading, selectAgent }
}

export type AgentScope = ReturnType<typeof useAgentScope>

/** Agent selector for the list toolbar's filter slot. */
export function AgentFilter({ scope }: { scope: AgentScope }) {
  const { t } = useTranslation()

  return (
    <Select value={scope.agentUID} onValueChange={value => scope.selectAgent(String(value))}>
      <SelectTrigger aria-label={t('console.agents.agent')} className="w-56">
        <SelectValue placeholder={t('console.select_agent')} />
      </SelectTrigger>
      <SelectContent>
        {scope.agents.map(agent => (
          <SelectItem key={agent.uid} value={agent.uid}>
            {agent.uid}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
