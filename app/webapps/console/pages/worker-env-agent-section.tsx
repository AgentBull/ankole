import {
  Badge,
  Button,
  Checkbox,
  Input,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiEyeLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebWorkerEnvControllerDecryptForAgentMutation,
  ankoleWebWorkerEnvControllerDeleteForAgentMutation,
  ankoleWebWorkerEnvControllerIndexForAgentOptions,
  ankoleWebWorkerEnvControllerUpdateForAgentMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { WorkerEnvItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { ErrorBlock } from '../console-primitives'
import { SecretInput } from '../console-shell'
import { WORKER_ENV_NAME_FORMAT, WorkerEnvSourceBadge, workerEnvValueText } from './worker-envs'

type OverrideDraft = { name: string; value: string; secret: boolean }

const emptyDraft: OverrideDraft = { name: '', value: '', secret: false }

/**
 * Effective shell environment for one agent, embedded in the agent editor.
 *
 * The rows mirror exactly what the agent's shells receive: declared exports,
 * custom global variables, and this agent's overrides, with the winning tier
 * badged per row. Editing here always writes the agent tier; installation-wide
 * values live on the Worker env page.
 */
export function WorkerEnvAgentSection({ agentUID }: { agentUID: string }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebWorkerEnvControllerIndexForAgentOptions({ path: { agent_uid: agentUID } }))
  const items = list.data?.worker_envs ?? []
  const [draft, setDraft] = useState<OverrideDraft>(emptyDraft)
  const [editing, setEditing] = useState<string>()
  const [revealed, setRevealed] = useState<Record<string, string>>({})
  const [draftError, setDraftError] = useState<string>()

  const refresh = () => void queryClient.invalidateQueries()
  const save = useMutation({
    ...ankoleWebWorkerEnvControllerUpdateForAgentMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.worker_envs.saved', { name: variables.path.name }))
      setDraft(emptyDraft)
      setEditing(undefined)
      setDraftError(undefined)
      refresh()
    },
    onError: error => setDraftError(requestErrorMessage(error))
  })
  const clear = useMutation({
    ...ankoleWebWorkerEnvControllerDeleteForAgentMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.worker_envs.cleared', { name: variables.path.name }))
      refresh()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const decrypt = useMutation({
    ...ankoleWebWorkerEnvControllerDecryptForAgentMutation(),
    gcTime: 0,
    onSuccess: response => {
      const value = response.decrypted_value.value
      setRevealed(current => ({
        ...current,
        [response.decrypted_value.name]: typeof value === 'string' ? value : JSON.stringify(value)
      }))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  const beginOverride = (item: WorkerEnvItem) => {
    setEditing(item.name)
    setDraft({
      name: item.name,
      value: item.secret ? '' : typeof item.value === 'string' ? item.value : '',
      secret: item.secret
    })
    setDraftError(undefined)
  }

  const submitDraft = () => {
    const name = draft.name.trim()
    if (!WORKER_ENV_NAME_FORMAT.test(name)) {
      setDraftError(t('console.worker_envs.name_invalid'))
      return
    }
    if (draft.value.length === 0) {
      setDraftError(t('console.worker_envs.value_required'))
      return
    }
    save.mutate({
      body: { value: draft.value, secret: draft.secret },
      path: { agent_uid: agentUID, name }
    })
  }

  const draftRow = (mode: 'add' | 'edit') => (
    <TableRow>
      <TableCell>
        {mode === 'add' ? (
          <Input
            className="font-mono"
            placeholder="NPM_TOKEN"
            spellCheck={false}
            value={draft.name}
            onChange={event => setDraft(current => ({ ...current, name: event.target.value }))}
          />
        ) : (
          <span className="font-mono text-xs">{draft.name}</span>
        )}
      </TableCell>
      <TableCell colSpan={2}>
        {draft.secret ? (
          <SecretInput
            value={draft.value}
            onChange={event => setDraft(current => ({ ...current, value: event.target.value }))}
          />
        ) : (
          <Input
            className="font-mono"
            spellCheck={false}
            value={draft.value}
            onChange={event => setDraft(current => ({ ...current, value: event.target.value }))}
          />
        )}
      </TableCell>
      <TableCell>
        <label className="flex items-center gap-2 text-xs text-muted-foreground">
          <Checkbox
            checked={draft.secret}
            onCheckedChange={checked => setDraft(current => ({ ...current, secret: checked === true }))}
          />
          {t('console.worker_envs.secret')}
        </label>
      </TableCell>
      <TableCell className="text-right">
        <div className="flex items-center justify-end gap-1">
          <Button disabled={save.isPending} size="xs" type="button" onClick={submitDraft}>
            {t('common.save')}
          </Button>
          <Button
            size="xs"
            type="button"
            variant="ghost"
            onClick={() => {
              setDraft(emptyDraft)
              setEditing(undefined)
              setDraftError(undefined)
            }}>
            {t('common.cancel')}
          </Button>
        </div>
      </TableCell>
    </TableRow>
  )

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.worker_envs.agent_section_title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.worker_envs.agent_section_description')}</p>
      </div>
      <ErrorBlock error={list.error ?? draftError} />
      <div className="overflow-hidden border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t('console.worker_envs.name')}</TableHead>
              <TableHead>{t('console.worker_envs.value')}</TableHead>
              <TableHead>{t('console.worker_envs.kind')}</TableHead>
              <TableHead>{t('console.worker_envs.source')}</TableHead>
              <TableHead className="w-0 text-right">
                <span className="sr-only">{t('console.actions')}</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map(item =>
              editing === item.name ? (
                draftRow('edit')
              ) : (
                <TableRow key={item.name}>
                  <TableCell className="max-w-[220px] font-mono text-xs break-all whitespace-normal">
                    {item.name}
                  </TableCell>
                  <TableCell className="max-w-[260px] font-mono text-xs text-muted-foreground">
                    <div className="flex items-center gap-1.5">
                      <span className="truncate">{revealed[item.name] ?? workerEnvValueText(item)}</span>
                      {item.secret && revealed[item.name] === undefined ? (
                        <button
                          aria-label={t('console.worker_envs.reveal')}
                          className="text-muted-foreground hover:text-foreground"
                          type="button"
                          onClick={() => decrypt.mutate({ path: { agent_uid: agentUID, name: item.name } })}>
                          <RiEyeLine className="size-3.5" />
                        </button>
                      ) : null}
                    </div>
                  </TableCell>
                  <TableCell>
                    <Badge variant={item.kind === 'declared' ? 'outline' : 'secondary'}>
                      {t(`console.worker_envs.kind_${item.kind}`)}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <WorkerEnvSourceBadge source={item.source} />
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex items-center justify-end gap-1">
                      <Button size="xs" type="button" variant="ghost" onClick={() => beginOverride(item)}>
                        {item.source === 'agent' ? t('common.edit') : t('console.worker_envs.override')}
                      </Button>
                      {item.source === 'agent' ? (
                        <Button
                          disabled={clear.isPending}
                          size="xs"
                          type="button"
                          variant="ghost"
                          onClick={() => clear.mutate({ path: { agent_uid: agentUID, name: item.name } })}>
                          {t('console.worker_envs.clear_override')}
                        </Button>
                      ) : null}
                    </div>
                  </TableCell>
                </TableRow>
              )
            )}
            {editing === undefined ? draftRow('add') : null}
          </TableBody>
        </Table>
      </div>
    </section>
  )
}
