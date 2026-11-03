import {
  Switch,
  Combobox,
  ComboboxChip,
  ComboboxChips,
  ComboboxChipsInput,
  ComboboxCollection,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxItem,
  ComboboxList,
  ComboboxValue,
  useComboboxAnchor
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError } from './content-primitives'
import {
  metaKeys,
  metaSkillQuery,
  metaAgentsQuery,
  ensurePodPersonalAssistant,
  metaSkillSetAll,
  metaSkillSetBinding,
  type MetaSkill,
  type MetaAgent
} from './meta-api'

export function SkillBindings({ skill }: { skill: MetaSkill }) {
  const { t } = useTranslation()
  const id = useId()
  const anchor = useComboboxAnchor()
  const detail = useQuery(metaSkillQuery(skill.slug))
  const agents = useQuery(metaAgentsQuery())
  const client = useQueryClient()
  const current = detail.data?.skill ?? skill
  const colleagues = agents.data?.agents.filter(agent => agent.type === 'ai_colleague') ?? []
  const assistant = agents.data?.agents.find(agent => agent.type === 'personal_assistant')
  const bound = detail.data?.agent_uids ?? []
  const selected = colleagues.filter(agent => current.enabled_for_all || bound.includes(agent.uid))
  const bind = (uid: string, enabled: boolean) =>
    metaSkillSetBinding({
      path: { slug: skill.slug },
      body: { data: { agent_uid: uid, enabled } }
    })
  const change = useMutation({
    mutationFn: async (
      action:
        | { kind: 'all'; enabled: boolean }
        | { kind: 'assistant'; enabled: boolean }
        | { kind: 'colleagues'; agents: MetaAgent[] }
    ) => {
      if (action.kind === 'all') {
        return metaSkillSetAll({
          path: { slug: skill.slug },
          body: { data: { enabled: action.enabled, base_revision: current.revision } }
        })
      }
      if (action.kind === 'assistant') {
        const uid = assistant?.uid ?? (await ensurePodPersonalAssistant()).uid
        return bind(uid, action.enabled)
      }
      const next = new Set(action.agents.map(agent => agent.uid))
      const results = await Promise.allSettled(
        colleagues
          .filter(agent => agent.can_bind && bound.includes(agent.uid) !== next.has(agent.uid))
          .map(agent => bind(agent.uid, next.has(agent.uid)))
      )
      const failed = results.find(result => result.status === 'rejected')
      if (failed?.status === 'rejected') throw failed.reason
    },
    onSettled: () =>
      Promise.all([
        client.invalidateQueries({ queryKey: metaKeys.skills() }),
        client.invalidateQueries({ queryKey: metaKeys.agents() })
      ])
  })
  const disabled = current.enabled_for_all || !detail.data || change.isPending
  return (
    <fieldset className="mt-4 space-y-4 border-t border-border pt-4">
      <legend className="text-sm font-medium">{t('pod.meta.enablement')}</legend>
      <div className="flex items-center justify-between gap-4 text-sm">
        <label htmlFor={`${id}-all`}>{t('pod.meta.all_agents')}</label>
        <Switch
          id={`${id}-all`}
          checked={current.enabled_for_all}
          disabled={!current.can_bind_all || change.isPending}
          onCheckedChange={enabled => change.mutate({ kind: 'all', enabled })}
        />
      </div>
      <div className="space-y-2 text-sm">
        <label htmlFor={`${id}-colleagues`}>{t('pod.meta.colleagues')}</label>
        {colleagues.some(agent => agent.can_bind) ? (
          <Combobox<MetaAgent, true>
            multiple
            items={colleagues}
            value={selected}
            disabled={disabled}
            isItemEqualToValue={(a, b) => a.uid === b.uid}
            itemToStringLabel={agent => agent.display_name}
            itemToStringValue={agent => agent.uid}
            onValueChange={next => change.mutate({ kind: 'colleagues', agents: next })}>
            <ComboboxChips ref={anchor}>
              <ComboboxValue>
                {(values: MetaAgent[]) =>
                  values.map(agent => (
                    <ComboboxChip
                      key={agent.uid}
                      showRemove={agent.can_bind}
                      removeLabel={t('pod.meta.disable_for', { name: agent.display_name })}>
                      {agent.display_name}
                    </ComboboxChip>
                  ))
                }
              </ComboboxValue>
              <ComboboxChipsInput id={`${id}-colleagues`} placeholder={t('pod.meta.find_agent')} />
            </ComboboxChips>
            <ComboboxContent anchor={anchor}>
              <ComboboxList>
                <ComboboxEmpty>{t('pod.content.no_matches')}</ComboboxEmpty>
                <ComboboxCollection>
                  {(agent: MetaAgent) => (
                    <ComboboxItem key={agent.uid} value={agent} disabled={!agent.can_bind}>
                      {agent.display_name}
                    </ComboboxItem>
                  )}
                </ComboboxCollection>
              </ComboboxList>
            </ComboboxContent>
          </Combobox>
        ) : (
          <p className="text-fg-secondary">
            {selected.map(agent => agent.display_name).join(', ') || t('pod.meta.no_colleagues_enabled')}
          </p>
        )}
      </div>
      <div className="flex items-center justify-between gap-4 text-sm">
        <label htmlFor={`${id}-assistant`}>{t('pod.meta.assistant')}</label>
        <Switch
          id={`${id}-assistant`}
          checked={current.enabled_for_all || (!!assistant && bound.includes(assistant.uid))}
          disabled={disabled || !agents.data || (!!assistant && !assistant.can_bind)}
          onCheckedChange={enabled => change.mutate({ kind: 'assistant', enabled })}
        />
      </div>
      {current.enabled_for_all && <p className="text-xs text-fg-secondary">{t('pod.meta.all_agents_hint')}</p>}
      {change.error && <ContentError error={change.error} />}
      {detail.error && <ContentError error={detail.error} retry={() => void detail.refetch()} />}
      {agents.error && <ContentError error={agents.error} retry={() => void agents.refetch()} />}
    </fieldset>
  )
}
