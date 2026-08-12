import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router'
import { ankoleWebAgentControllerIndexOptions } from './api/generated/@tanstack/react-query.gen'

/**
 * The agent a list page is scoped to, held in `?agent=`. Without the
 * parameter the page covers every agent.
 *
 * The console list endpoints are installation-wide and take the selected
 * agent as an optional filter. Pages pass `agentUID || undefined` straight
 * into that query parameter.
 */
export function useAgentScope() {
  const [searchParams, setSearchParams] = useSearchParams()
  const agents = useQuery(ankoleWebAgentControllerIndexOptions())
  const agentUID = searchParams.get('agent') ?? ''

  // Only the `agent` key changes: the other parameters, such as an open
  // `?job=` detail, stay valid across a scope change and must survive it.
  const selectAgent = (uid: string) =>
    setSearchParams(current => {
      const next = new URLSearchParams(current)
      if (uid) next.set('agent', uid)
      else next.delete('agent')
      return next
    })

  return {
    /** Selected agent UID, or empty while the page covers every agent. */
    agentUID,
    agents: agents.data?.agents ?? [],
    error: agents.error,
    isLoading: agents.isLoading,
    selectAgent
  }
}

export type AgentScope = ReturnType<typeof useAgentScope>

/**
 * A known requested agent resolves to itself. An unknown request resolves to
 * '' so the operator must choose explicitly. No request resolves to the first
 * known agent.
 */
export function resolveAgentUID(agents: readonly { uid: string }[], requestedUID: string): string {
  if (requestedUID) return agents.some(agent => agent.uid === requestedUID) ? requestedUID : ''
  return agents[0]?.uid ?? ''
}

/** Agent selector for the list toolbar's filter slot. */
export function AgentFilter({ scope }: { scope: AgentScope }) {
  const { t } = useTranslation()

  return (
    <Select
      value={scope.agentUID || null}
      onValueChange={value => scope.selectAgent(value == null ? '' : String(value))}>
      {/* The all-agents state is the null value, which the trigger styles as an
          unfilled placeholder; it is a real scope, so keep the label readable. */}
      <SelectTrigger aria-label={t('console.agents.agent')} className="w-56 data-placeholder:text-foreground">
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value={null}>{t('console.all_agents')}</SelectItem>
        {scope.agents.map(agent => (
          <SelectItem key={agent.uid} value={agent.uid}>
            {agent.uid}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
