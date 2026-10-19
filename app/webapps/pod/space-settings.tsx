import { t } from 'i18next'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient, type UseMutationResult } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { contentKeys, type PageRole } from './content-api'
import {
  podSpace,
  podSpaceWrite,
  podSpaceAgent,
  podSpaceAgentDelete,
  podSubjects
} from '../common/api/generated/sdk.gen'
import type { PodSpace as Space } from '../common/api/generated/types.gen'
import { Choice, ContentError, roleLabels } from './content-primitives'

type SpaceChange =
  | { type: 'role'; role: PageRole }
  | { type: 'grant'; principal_uid: string; role: PageRole }
  | { type: 'remove'; principal_uid: string }

export function SpaceSettingsButton() {
  const [open, setOpen] = useState(false)
  const client = useQueryClient()
  const saving = useRef(false)
  const mutate = useMutation({
    mutationFn: async (change: SpaceChange): Promise<unknown> => {
      switch (change.type) {
        case 'role':
          return podSpaceWrite({ body: { role: change.role } })
        case 'grant':
          return podSpaceAgent({ body: { principal_uid: change.principal_uid, role: change.role } })
        case 'remove':
          return podSpaceAgentDelete({ path: { uid: change.principal_uid } })
      }
    },
    onSuccess: () => client.invalidateQueries({ queryKey: contentKeys.all }),
    onSettled: () => {
      saving.current = false
    }
  })
  const commit = (change: SpaceChange, onSuccess?: () => void) => {
    if (saving.current) return
    saving.current = true
    mutate.mutate(change, { onSuccess })
  }
  const space = useQuery({ queryKey: [...contentKeys.all, 'space'], queryFn: () => podSpace() })
  return space.data?.can_manage ? (
    <Dialog open={open} onOpenChange={next => !saving.current && setOpen(next)}>
      <Button
        size="icon-sm"
        variant="ghost"
        aria-label={t('pod.content.space_settings')}
        onClick={() => {
          mutate.reset()
          setOpen(true)
        }}>
        ⋯
      </Button>
      <DialogContent
        className="pod-dialog pod-dialog-wide"
        closeLabel={t('common.close')}
        showCloseButton={!mutate.isPending}
        aria-busy={mutate.isPending}>
        <DialogTitle>{t('pod.content.space_settings')}</DialogTitle>
        {open && <SpaceSettings space={space.data} close={() => setOpen(false)} mutate={mutate} commit={commit} />}
      </DialogContent>
    </Dialog>
  ) : null
}

function SpaceSettings({
  space,
  close,
  mutate,
  commit
}: {
  space: Space
  close(): void
  mutate: UseMutationResult<unknown, Error, SpaceChange>
  commit(change: SpaceChange, onSuccess?: () => void): void
}) {
  const [role, setRole] = useState(space.role)
  const [agent, setAgent] = useState('')
  const [agentRole, setAgentRole] = useState<PageRole>('edit')
  const subjects = useQuery({
    queryKey: [...contentKeys.all, 'subjects'],
    queryFn: () => podSubjects()
  })
  const agents = subjects.data?.subjects.filter(subject => subject.kind === 'agent' && !!subject.principal_uid) ?? []
  return (
    <form
      className="contents"
      onSubmit={event => {
        event.preventDefault()
        commit({ type: 'role', role }, close)
      }}>
      <div className="pod-dialog-body grid gap-4">
        <label className="grid gap-2 text-sm">
          <span>{t('pod.content.default_permissions_for_members')}</span>
          <Choice
            label={t('pod.content.default_member_permission')}
            value={role}
            onChange={setRole}
            options={roleLabels}
            disabled={mutate.isPending}
          />
        </label>
        <p className="text-xs text-fg-tertiary">
          {t('pod.content.administrators_can_still_manage_all_unrestricted_space_pages_private_and')}
        </p>
        <h3 className="text-sm font-semibold">{t('pod.content.agents_in_this_space')}</h3>
        <ul className="divide-y divide-border">
          {space.agents.map(agent => (
            <li
              key={agent.principal_uid ?? agent.group_id}
              className="flex items-center justify-between gap-2 py-2 text-sm">
              <span>{agent.name ?? agent.principal_uid}</span>
              <span>{roleLabels[agent.role]}</span>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={mutate.isPending}
                onClick={() => agent.principal_uid && commit({ type: 'remove', principal_uid: agent.principal_uid })}>
                {t('pod.content.remove')}
              </Button>
            </li>
          ))}
        </ul>
        <div className="flex flex-wrap gap-2">
          <Choice
            label={t('pod.content.choose_an_agent')}
            value={agent}
            disabled={mutate.isPending}
            onChange={setAgent}
            options={{
              '': t('pod.content.choose_an_agent'),
              ...Object.fromEntries(agents.map(agent => [agent.principal_uid, agent.name]))
            }}
          />
          <Choice
            label={t('pod.content.agent_permission')}
            value={agentRole}
            onChange={setAgentRole}
            options={roleLabels}
            disabled={mutate.isPending}
          />
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={!agent || mutate.isPending}
            onClick={() => commit({ type: 'grant', principal_uid: agent, role: agentRole })}>
            {t('pod.content.add_to_space')}
          </Button>
        </div>
        <ContentError error={mutate.error || subjects.error} />
      </div>
      <DialogFooter>
        <Button type="button" variant="ghost" disabled={mutate.isPending} onClick={close}>
          {t('pod.content.cancel')}
        </Button>
        <Button variant="outline" type="submit" disabled={mutate.isPending}>
          {t('pod.content.save_default_permissions')}
        </Button>
      </DialogFooter>
    </form>
  )
}
