import { useEffect, useRef } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue, Button } from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { podModelProfiles, podModelSelection, setPodModelSelection } from '../common/api/generated/sdk.gen'
import { podKeys } from './api'

export const modelSelectionKey = (conversationID: string) =>
  [...podKeys.detail(conversationID), 'model-profile'] as const

type ModelControlsProps = {
  agentUID: string
  conversationID?: string
  draftProfile: string | null
  onDraftProfileChange(profile: string | null): void
  onRequiresQueue(required: boolean): void
  activeSignalID?: string | null
  disabled?: boolean
}

/** The server owns existing Chat preferences; a new Chat keeps its choice with its draft. */
export function ModelControls({
  agentUID,
  conversationID,
  draftProfile,
  onDraftProfileChange,
  onRequiresQueue,
  activeSignalID,
  disabled
}: ModelControlsProps) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const key = conversationID ? modelSelectionKey(conversationID) : [...podKeys.agents, agentUID, 'model-profiles']
  const selection = useQuery({
    queryKey: key,
    queryFn: async () => {
      if (conversationID) return podModelSelection({ path: { id: conversationID } })
      const catalog = await podModelProfiles({ path: { uid: agentUID } })
      return { ...catalog, profile: null, activeProfile: null }
    },
    enabled: !!agentUID
  })
  const save = useMutation({
    mutationKey: conversationID ? modelSelectionKey(conversationID) : undefined,
    mutationFn: ({ id, profile }: { id: string; profile: string | null }) =>
      setPodModelSelection({ path: { id }, body: { profile } }),
    onSuccess: (result, submitted) => client.setQueryData(modelSelectionKey(submitted.id), result)
  })
  const previousSignal = useRef(activeSignalID)
  useEffect(() => {
    if (previousSignal.current !== activeSignalID) {
      previousSignal.current = activeSignalID
      if (conversationID) void client.invalidateQueries({ queryKey: modelSelectionKey(conversationID), exact: true })
    }
  }, [activeSignalID, client, conversationID])

  const profile = conversationID ? (selection.data?.profile ?? null) : draftProfile
  const activeProfile = selection.data?.activeProfile
  const requiresQueue = !!activeProfile && activeProfile !== (profile ?? 'primary')
  useEffect(() => onRequiresQueue(requiresQueue), [requiresQueue, onRequiresQueue])
  const profiles = selection.data?.profiles ?? []
  const unavailable = !!profile && !profiles.some(option => option.name === profile)
  const label = selection.isPending ? t('pod.content.loading') : profile ? profile : t('pod.chat.model_follow_agent')
  const choose = (value: string) => {
    const next = value === '__agent_default__' ? null : value
    if (conversationID) save.mutate({ id: conversationID, profile: next })
    else onDraftProfileChange(next)
  }

  return (
    <div role="group" aria-label={t('pod.chat.model')} className="min-w-0">
      <Select
        value={profile ?? '__agent_default__'}
        onValueChange={value => value && choose(value)}
        onOpenChange={open => open && void selection.refetch()}
        disabled={disabled || selection.isPending || selection.isError || save.isPending}>
        <SelectTrigger size="sm" aria-label={t('pod.chat.model')} title={label} className="max-w-48">
          <SelectValue>{label}</SelectValue>
          {save.isPending && (
            <span role="status" className="text-xs text-fg-tertiary">
              {t('pod.chat.model_saving')}
            </span>
          )}
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__agent_default__">{t('pod.chat.model_follow_agent')}</SelectItem>
          {unavailable && (
            <SelectItem value={profile!} disabled>
              {profile} · {t('pod.chat.model_unavailable')}
            </SelectItem>
          )}
          {profiles.map(option => (
            <SelectItem key={option.name} value={option.name}>
              <span className="flex min-w-0 flex-col">
                <span>{option.name}</span>
                <span className="max-w-64 truncate text-xs text-muted-foreground">{option.description}</span>
              </span>
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {requiresQueue && <p className="mt-1 text-xs text-muted-foreground">{t('pod.chat.model_for_next_reply')}</p>}
      {(save.isError || selection.isError) && (
        <p role="alert" className="mt-1 text-xs text-destructive">
          {t('pod.chat.model_save_failed')}
        </p>
      )}
      {selection.isError && (
        <Button variant="ghost" size="sm" onClick={() => void selection.refetch()}>
          {t('pod.content.retry')}
        </Button>
      )}
    </div>
  )
}
