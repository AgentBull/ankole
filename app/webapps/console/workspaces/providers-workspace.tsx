import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  TableCell,
  TableRow,
  Textarea
} from '@ankole/uikit'
import { RiAddLine, RiDeleteBin6Line, RiSave3Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAiGatewayProviderControllerDeleteProviderMutation,
  ankoleWebAiGatewayProviderControllerIndexOptions,
  ankoleWebAiGatewayProviderControllerProviderKindsOptions,
  ankoleWebAiGatewayProviderControllerPutProviderMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { AiGatewayProviderItem, AiGatewayProviderKindItem } from '../api/generated/types.gen'
import {
  ErrorBlock,
  Field,
  ResourceTable,
  WorkspaceShell,
  blankToNull,
  formatJson,
  parseObjectDraft,
  useSelectFirst
} from '../console-primitives'

type ProviderDraft = {
  providerId: string
  providerKind: string
  baseUrl: string
  connectionOptions: string
  error?: string
}

export function ProvidersWorkspace() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const providers = useQuery(ankoleWebAiGatewayProviderControllerIndexOptions())
  const providerKinds = useQuery(ankoleWebAiGatewayProviderControllerProviderKindsOptions())
  const [mode, setMode] = useState<'new' | 'edit'>('new')
  const [selectedId, setSelectedId] = useSelectFirst(
    providers.data?.data,
    provider => provider.provider_id,
    () => setMode('edit')
  )
  const selected = providers.data?.data.find(provider => provider.provider_id === selectedId)
  const [draft, setDraft] = useState<ProviderDraft>(emptyProviderDraft())
  const refresh = () => void queryClient.invalidateQueries()
  const saveProvider = useMutation({ ...ankoleWebAiGatewayProviderControllerPutProviderMutation(), onSuccess: refresh })
  const deleteProvider = useMutation({
    ...ankoleWebAiGatewayProviderControllerDeleteProviderMutation(),
    onSuccess: () => {
      setMode('new')
      setSelectedId(null)
      refresh()
    }
  })

  useEffect(() => {
    setDraft(
      mode === 'edit' && selected ? draftFromProvider(selected) : emptyProviderDraft(providerKinds.data?.data[0])
    )
  }, [mode, selected?.provider_id, providerKinds.data?.data])

  const submit = () => {
    const parsed = parseObjectDraft(draft.connectionOptions, 'connection_options')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }

    const providerId = draft.providerId.trim()
    saveProvider.mutate({
      body: {
        provider_id: providerId,
        provider_kind: draft.providerKind,
        base_url: blankToNull(draft.baseUrl),
        connection_options: parsed.value
      },
      path: { provider_id: providerId }
    })
  }

  return (
    <WorkspaceShell
      title={t('console.providers.title')}
      action={
        <Button
          size="sm"
          type="button"
          variant="outline"
          onClick={() => {
            setMode('new')
            setSelectedId(null)
          }}>
          <RiAddLine data-icon="inline-start" />
          {t('common.new')}
        </Button>
      }>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(420px,1.05fr)]">
        <div className="min-w-0">
          <ErrorBlock error={providers.error ?? providerKinds.error} />
          <ResourceTable
            columns={[t('console.providers.provider'), t('console.providers.kind'), t('console.providers.credentials')]}
            empty={!providers.isLoading && (providers.data?.data.length ?? 0) === 0}
            loading={providers.isLoading}>
            {providers.data?.data.map(provider => (
              <TableRow
                key={provider.provider_id}
                data-state={provider.provider_id === selected?.provider_id ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => {
                  setMode('edit')
                  setSelectedId(provider.provider_id)
                }}>
                <TableCell className="font-mono text-xs">{provider.provider_id}</TableCell>
                <TableCell>{provider.provider_kind}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-2">
                    {Object.entries(provider.encrypted_options).map(([key, option]) => (
                      <Badge key={key} variant={option.present ? 'default' : 'outline'}>
                        {key}
                      </Badge>
                    ))}
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>
        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle>{mode === 'new' ? t('console.providers.new') : selected?.provider_id}</CardTitle>
              {mode === 'edit' && selected ? (
                <Button
                  aria-label={t('console.aria.disable_provider')}
                  disabled={deleteProvider.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => deleteProvider.mutate({ path: { provider_id: selected.provider_id } })}>
                  <RiDeleteBin6Line />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            <ErrorBlock error={draft.error ?? saveProvider.error ?? deleteProvider.error} />
            <Field label={t('console.providers.provider_id')}>
              <Input
                disabled={mode === 'edit'}
                value={draft.providerId}
                onChange={event => setDraft(current => ({ ...current, providerId: event.target.value }))}
              />
            </Field>
            <Field label={t('console.providers.kind')}>
              <Select
                value={draft.providerKind}
                onValueChange={value => setDraft(current => ({ ...current, providerKind: String(value) }))}>
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(providerKinds.data?.data ?? []).map(kind => (
                    <SelectItem key={kind.provider_kind} value={kind.provider_kind}>
                      {providerKindLabel(kind)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label={t('console.providers.base_url')}>
              <Input
                value={draft.baseUrl}
                onChange={event => setDraft(current => ({ ...current, baseUrl: event.target.value }))}
              />
            </Field>
            <Field label={t('console.providers.connection_options')}>
              <Textarea
                className="min-h-52 font-mono text-xs"
                spellCheck={false}
                value={draft.connectionOptions}
                onChange={event => setDraft(current => ({ ...current, connectionOptions: event.target.value }))}
              />
            </Field>
            <Button disabled={saveProvider.isPending} size="sm" type="button" onClick={submit}>
              <RiSave3Line data-icon="inline-start" />
              {t('common.save')}
            </Button>
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function emptyProviderDraft(kind?: AiGatewayProviderKindItem): ProviderDraft {
  return {
    providerId: '',
    providerKind: kind?.provider_kind ?? '',
    baseUrl: kind?.default_base_url ?? '',
    connectionOptions: '{}'
  }
}

function draftFromProvider(provider: AiGatewayProviderItem): ProviderDraft {
  return {
    providerId: provider.provider_id,
    providerKind: provider.provider_kind,
    baseUrl: provider.base_url ?? '',
    connectionOptions: formatJson(provider.connection_options)
  }
}

function providerKindLabel(kind: AiGatewayProviderKindItem): string {
  const label = kind.label.en ?? kind.label['en-US'] ?? kind.provider_kind
  return `${label} (${kind.provider_kind})`
}
