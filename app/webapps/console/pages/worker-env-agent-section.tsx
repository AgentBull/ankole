import {
  Button,
  Input,
  Skeleton,
  Switch,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { RiEyeLine, RiEyeOffLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState, type SetStateAction } from 'react'
import { useTranslation } from 'react-i18next'
import {
  decryptAgentWorkerEnvMutation,
  deleteAgentWorkerEnvMutation,
  listAgentWorkerEnvsOptions,
  updateAgentWorkerEnvMutation
} from '../api/v2/generated/@tanstack/react-query.gen'
import type { WorkerEnvItem } from '../api/configuration-types'
import { requestErrorMessage } from '../../common/request-errors'
import { ConfirmDeleteButton, SaveButton } from '../console-form'
import { ErrorBlock } from '../../common/error-block'
import { ENCRYPTED_VALUE_MASK, EncryptedValueInput, isEncryptedValueMask } from '../encrypted-value-input'
import { workerEnvValueText } from '../state/worker-env-visibility'
import {
  WORKER_ENV_NAME_FORMAT,
  WorkerEnvPlaintextConfirmDialog,
  WorkerEnvPlaintextWarning,
  WorkerEnvSourceBadge
} from './worker-envs'

type OverrideDraft = { name: string; value: string; secret: boolean }

const emptyDraft: OverrideDraft = { name: '', value: '', secret: true }

/**
 * Effective shell environment for one agent, embedded in the agent editor.
 *
 * The rows mirror exactly what the agent's shells receive: operator variables,
 * custom global variables, and this agent's overrides, with the winning tier
 * badged per row. Editing here always writes the agent tier; installation-wide
 * values live on the Worker env page.
 */
export function WorkerEnvAgentSection({
  agentUID,
  onDirtyChange
}: {
  agentUID: string
  onDirtyChange?: (dirty: boolean) => void
}) {
  const { t } = useTranslation()
  const list = useQuery(listAgentWorkerEnvsOptions({ path: { agent_uid: agentUID } }))
  const items = list.data?.worker_envs ?? []
  const [draft, setDraftState] = useState<OverrideDraft>(emptyDraft)
  const editGeneration = useRef(0)
  const setDraft = (next: SetStateAction<OverrideDraft>) => {
    editGeneration.current++
    setDraftState(next)
  }
  useEffect(
    () => () => {
      editGeneration.current++
    },
    []
  )
  const [editing, setEditing] = useState<string>()
  const [revealed, setRevealed] = useState<Record<string, string>>({})
  const revealTimers = useRef<Record<string, number>>({})
  const revealRequests = useRef<Record<string, symbol>>({})
  const [draftError, setDraftError] = useState<string>()
  const [plaintextConfirmOpen, setPlaintextConfirmOpen] = useState(false)
  const nameInput = useRef<HTMLInputElement>(null)
  const valueInput = useRef<HTMLInputElement>(null)

  const save = useMutation({
    ...updateAgentWorkerEnvMutation(),
    onMutate: () => editGeneration.current,
    onSuccess: (_data, variables, generation) => {
      hideRevealed(variables.path.name)
      if (generation !== editGeneration.current) return
      toast.success(t('console.worker_envs.saved', { name: variables.path.name }))
      setDraft(emptyDraft)
      setEditing(undefined)
      setDraftError(undefined)
      setPlaintextConfirmOpen(false)
    },
    onError: (error, _variables, generation) => {
      if (generation === editGeneration.current) setDraftError(requestErrorMessage(error))
    }
  })
  const clear = useMutation({
    ...deleteAgentWorkerEnvMutation(),
    onSuccess: (_data, variables) => {
      hideRevealed(variables.path.name)
      toast.success(t('console.worker_envs.cleared', { name: variables.path.name }))
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const decrypt = useMutation({
    meta: { invalidates: false },
    ...decryptAgentWorkerEnvMutation(),
    gcTime: 0,
    onMutate: variables => {
      const request = Symbol()
      revealRequests.current[variables.path.name] = request
      return { generation: editGeneration.current, request }
    },
    onSuccess: (response, _variables, context) => {
      const { name, value } = response.decrypted_value
      if (revealRequests.current[name] !== context.request) return
      delete revealRequests.current[name]
      if (context.generation !== editGeneration.current) return
      setRevealed(current => ({
        ...current,
        [name]: value
      }))
      window.clearTimeout(revealTimers.current[name])
      revealTimers.current[name] = window.setTimeout(() => hideRevealed(name), 30_000)
      setDraftState(current =>
        current.name === name && isEncryptedValueMask(current.value) ? { ...current, value } : current
      )
    },
    onError: error => toast.error(requestErrorMessage(error))
  })

  useEffect(() => {
    const remaskAll = () => {
      revealRequests.current = {}
      for (const timeout of Object.values(revealTimers.current)) window.clearTimeout(timeout)
      revealTimers.current = {}
      setRevealed({})
    }
    window.addEventListener('blur', remaskAll)
    return () => {
      window.removeEventListener('blur', remaskAll)
      revealRequests.current = {}
      for (const timeout of Object.values(revealTimers.current)) window.clearTimeout(timeout)
    }
  }, [])

  const hideRevealed = (name: string) => {
    delete revealRequests.current[name]
    window.clearTimeout(revealTimers.current[name])
    delete revealTimers.current[name]
    setRevealed(current => {
      const next = { ...current }
      delete next[name]
      return next
    })
  }

  const beginOverride = (item: WorkerEnvItem) => {
    setEditing(item.name)
    setDraft({
      name: item.name,
      value: item.secret
        ? (revealed[item.name] ?? (item.source === 'agent' ? ENCRYPTED_VALUE_MASK : ''))
        : (item.value ?? ''),
      secret: item.secret
    })
    setDraftError(undefined)
  }

  const persistDraft = () => {
    save.mutate({
      body: {
        data: {
          ...(isEncryptedValueMask(draft.value) ? {} : { value: draft.value }),
          secret: draft.secret
        }
      },
      path: { agent_uid: agentUID, name: draft.name.trim() }
    })
  }

  const submitDraft = () => {
    const name = draft.name.trim()
    if (!WORKER_ENV_NAME_FORMAT.test(name)) {
      setDraftError(t('console.worker_envs.name_invalid'))
      nameInput.current?.focus()
      return
    }
    if (draft.value.length === 0) {
      setDraftError(t('console.worker_envs.value_required'))
      valueInput.current?.focus()
      return
    }
    if (!draft.secret && isEncryptedValueMask(draft.value)) {
      setDraftError(t('console.worker_envs.plaintext_reveal_required'))
      valueInput.current?.focus()
      return
    }
    if (!draft.secret) {
      setPlaintextConfirmOpen(true)
      return
    }
    persistDraft()
  }

  const activeSource = editing !== undefined ? items.find(item => item.name === editing) : undefined
  const activeSourceValue = activeSource?.secret
    ? (revealed[activeSource.name] ?? ENCRYPTED_VALUE_MASK)
    : (activeSource?.value ?? '')
  const isDirty =
    editing !== undefined
      ? activeSource?.source === 'agent'
        ? !(
            draft.name === activeSource.name &&
            draft.value === activeSourceValue &&
            draft.secret === activeSource.secret
          )
        : Boolean(draft.value.length > 0 || draft.secret !== (activeSource?.secret ?? true))
      : Boolean(draft.name.trim() || draft.value.length > 0 || !draft.secret)

  useEffect(() => {
    onDirtyChange?.(isDirty)
    return () => onDirtyChange?.(false)
  }, [isDirty, onDirtyChange])

  const draftRow = (mode: 'add' | 'edit') => {
    const source = mode === 'edit' ? items.find(item => item.name === editing) : undefined
    const sourceValue = source?.secret ? (revealed[source.name] ?? ENCRYPTED_VALUE_MASK) : (source?.value ?? '')
    const unchanged = Boolean(
      source && draft.name === source.name && draft.value === sourceValue && draft.secret === source.secret
    )
    const incomplete =
      !WORKER_ENV_NAME_FORMAT.test(draft.name.trim()) ||
      draft.value.length === 0 ||
      (!draft.secret && isEncryptedValueMask(draft.value))
    const disabled = save.isPending || (unchanged && !incomplete)

    return (
      <TableRow key={mode === 'edit' ? editing : undefined}>
        <TableCell>
          {mode === 'add' ? (
            <Input
              ref={nameInput}
              aria-label={t('console.worker_envs.name')}
              required
              className="font-mono"
              placeholder="SOME_ENV_VAR"
              spellCheck={false}
              value={draft.name}
              onChange={event => setDraft(current => ({ ...current, name: event.target.value }))}
            />
          ) : (
            <span className="font-mono text-xs">{draft.name}</span>
          )}
        </TableCell>
        <TableCell>
          <div className="grid min-w-64 gap-2">
            {draft.secret || isEncryptedValueMask(draft.value) ? (
              <EncryptedValueInput
                ref={valueInput}
                aria-label={t('console.worker_envs.value')}
                required
                className="font-mono"
                revealLabel={t('console.worker_envs.reveal')}
                revealed={revealed[draft.name] !== undefined && !isEncryptedValueMask(draft.value)}
                revealing={decrypt.isPending}
                value={draft.value}
                onChange={event => setDraft(current => ({ ...current, value: event.target.value }))}
                onReveal={editing ? () => decrypt.mutate({ path: { agent_uid: agentUID, name: editing } }) : undefined}
              />
            ) : (
              <Input
                ref={valueInput}
                aria-label={t('console.worker_envs.value')}
                required
                className="font-mono"
                spellCheck={false}
                value={draft.value}
                onChange={event => setDraft(current => ({ ...current, value: event.target.value }))}
              />
            )}
            {!draft.secret ? <WorkerEnvPlaintextWarning compact /> : null}
          </div>
        </TableCell>
        <TableCell>
          <label className="flex cursor-pointer items-center gap-2 text-xs text-muted-foreground">
            <Switch
              checked={draft.secret}
              size="sm"
              onCheckedChange={checked => setDraft(current => ({ ...current, secret: checked }))}
            />
            {t('console.worker_envs.secret')}
          </label>
        </TableCell>
        <TableCell className="text-right">
          <div className="flex items-center justify-end gap-1">
            <SaveButton
              disabled={disabled}
              incomplete={incomplete && !disabled}
              loading={save.isPending}
              size="xs"
              type="button"
              onClick={submitDraft}>
              {t('common.save')}
            </SaveButton>
            {mode === 'edit' || draft.name || draft.value ? (
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
            ) : null}
          </div>
        </TableCell>
      </TableRow>
    )
  }

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.worker_envs.agent_section_title')}</h3>
        <p className="text-sm leading-6 text-muted-foreground">{t('console.worker_envs.agent_section_description')}</p>
      </div>
      <ErrorBlock error={list.error ?? draftError} />
      <div className="overflow-x-auto border border-border bg-card">
        <Table aria-busy={list.isLoading}>
          <TableHeader>
            <TableRow>
              <TableHead>{t('console.worker_envs.name')}</TableHead>
              <TableHead>{t('console.worker_envs.value')}</TableHead>
              <TableHead>{t('console.worker_envs.source')}</TableHead>
              <TableHead className="w-0 text-right">
                <span className="sr-only">{t('console.actions')}</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {list.isLoading ? (
              <TableRow>
                <TableCell colSpan={4}>
                  <div className="grid gap-2">
                    <Skeleton className="h-6 w-full" />
                    <Skeleton className="h-6 w-4/5" />
                  </div>
                </TableCell>
              </TableRow>
            ) : (
              <>
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
                          {item.secret ? (
                            <button
                              aria-label={
                                revealed[item.name] === undefined
                                  ? t('console.worker_envs.reveal')
                                  : t('console.aria.hide_secret')
                              }
                              className="grid size-9 shrink-0 place-items-center text-muted-foreground hover:bg-muted hover:text-foreground"
                              title={
                                revealed[item.name] === undefined
                                  ? t('console.worker_envs.reveal')
                                  : t('console.aria.hide_secret')
                              }
                              type="button"
                              onClick={() =>
                                revealed[item.name] === undefined
                                  ? decrypt.mutate({ path: { agent_uid: agentUID, name: item.name } })
                                  : hideRevealed(item.name)
                              }>
                              {revealed[item.name] === undefined ? (
                                <RiEyeLine className="size-4" />
                              ) : (
                                <RiEyeOffLine className="size-4" />
                              )}
                            </button>
                          ) : null}
                        </div>
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
                            <ConfirmDeleteButton
                              label={t('console.worker_envs.clear_override')}
                              pending={clear.isPending}
                              confirm={{
                                title: t('console.worker_envs.clear_confirm_title'),
                                description: t('console.worker_envs.clear_confirm_description', { name: item.name }),
                                confirmLabel: t('console.worker_envs.clear_override')
                              }}
                              onConfirm={() => clear.mutate({ path: { agent_uid: agentUID, name: item.name } })}
                            />
                          ) : null}
                        </div>
                      </TableCell>
                    </TableRow>
                  )
                )}
                {editing === undefined ? draftRow('add') : null}
              </>
            )}
          </TableBody>
        </Table>
      </div>
      <WorkerEnvPlaintextConfirmDialog
        open={plaintextConfirmOpen}
        pending={save.isPending}
        onOpenChange={setPlaintextConfirmOpen}
        onConfirm={() => {
          setPlaintextConfirmOpen(false)
          persistDraft()
        }}
      />
    </section>
  )
}
