import { Badge, Button, Card, CardContent, CardHeader, CardTitle, TableCell, TableRow, Textarea } from '@ankole/uikit'
import { RiCloseLine, RiEyeLine, RiSave3Line } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerDeleteMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem } from '../api/generated/types.gen'
import { ErrorBlock, ResourceTable, WorkspaceShell, formatJson, parseJson } from '../console-primitives'

type ConfigDraft = {
  text: string
  error?: string
}

export function AppConfigureWorkspace() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState<ConfigDraft>({ text: '' })
  const [revealed, setRevealed] = useState<unknown>(undefined)
  const items = list.data?.data ?? []
  const selected = selectedKey ? items.find(item => item.key === selectedKey) : firstConfig(items)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({
      path: { key: selected?.key ?? '' }
    }),
    enabled: Boolean(selected?.editable && selected.key)
  })
  const activeItem = detail.data?.data ?? selected
  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refresh()
    }
  })
  const reset = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refresh()
    }
  })
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    onSuccess: response => setRevealed(response.data.value)
  })

  // Auto-select the first editable item, not the raw [0]; kept local because this
  // workspace's selection target is intentionally different from useSelectFirst.
  useEffect(() => {
    if (!selectedKey && selected?.key) setSelectedKey(selected.key)
  }, [selected?.key, selectedKey])

  useEffect(() => {
    setRevealed(undefined)
    setDraft({
      text: formatJson(activeItem?.encrypted && activeItem.value === undefined ? {} : (activeItem?.value ?? null))
    })
  }, [activeItem?.key, activeItem?.source, activeItem?.value])

  const submit = () => {
    if (!activeItem) return
    const parsed = parseJson(draft.text, 'value')
    if (!parsed.ok) {
      setDraft(current => ({ ...current, error: parsed.error }))
      return
    }
    update.mutate({ body: { value: parsed.value }, path: { key: activeItem.key } })
  }

  return (
    <WorkspaceShell title={t('console.settings.title')}>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1.05fr)_minmax(420px,0.95fr)]">
        <div className="min-w-0">
          <ErrorBlock error={list.error} />
          <ResourceTable
            columns={[
              t('console.settings.key'),
              t('console.settings.kind'),
              t('console.settings.source'),
              t('console.identity.state')
            ]}
            empty={!list.isLoading && items.length === 0}
            loading={list.isLoading}>
            {items.map(item => (
              <TableRow
                key={`${item.kind}:${item.key}`}
                data-state={activeItem?.key === item.key ? 'selected' : undefined}
                className="cursor-pointer"
                onClick={() => setSelectedKey(item.key)}>
                <TableCell className="max-w-[320px] whitespace-normal font-mono text-xs">{item.key}</TableCell>
                <TableCell>
                  <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
                </TableCell>
                <TableCell>{item.source}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-2">
                    {item.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
                    {item.overridden ? <Badge>{t('console.status.global')}</Badge> : null}
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </ResourceTable>
        </div>
        <Card size="sm" className="min-w-0">
          <CardHeader>
            <div className="flex items-start justify-between gap-3">
              <CardTitle className="break-all font-mono text-base">
                {activeItem?.key ?? t('console.no_setting')}
              </CardTitle>
              {activeItem?.editable ? (
                <Button
                  aria-label={t('console.aria.reset')}
                  disabled={reset.isPending}
                  size="icon-sm"
                  type="button"
                  variant="outline"
                  onClick={() => reset.mutate({ path: { key: activeItem.key } })}>
                  <RiCloseLine />
                </Button>
              ) : null}
            </div>
          </CardHeader>
          <CardContent className="grid gap-4">
            {activeItem ? (
              <>
                <div className="flex flex-wrap gap-2">
                  <Badge variant={activeItem.kind === 'pattern' ? 'outline' : 'secondary'}>{activeItem.kind}</Badge>
                  <Badge variant="outline">{activeItem.source}</Badge>
                  {activeItem.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
                </div>
                {activeItem.description ? (
                  <p className="text-sm leading-6 text-muted-foreground">{activeItem.description}</p>
                ) : null}
                <ErrorBlock error={draft.error ?? update.error ?? reset.error ?? decrypt.error} />
                {activeItem.editable ? (
                  <>
                    <Textarea
                      className="min-h-64 font-mono text-xs"
                      spellCheck={false}
                      value={draft.text}
                      onChange={event => setDraft({ text: event.target.value })}
                    />
                    <div className="flex flex-wrap gap-2">
                      <Button disabled={update.isPending} size="sm" type="button" onClick={submit}>
                        <RiSave3Line data-icon="inline-start" />
                        {t('common.save')}
                      </Button>
                      {activeItem.encrypted ? (
                        <Button
                          disabled={decrypt.isPending}
                          size="sm"
                          type="button"
                          variant="outline"
                          onClick={() => decrypt.mutate({ path: { key: activeItem.key } })}>
                          <RiEyeLine data-icon="inline-start" />
                          {t('console.settings.reveal')}
                        </Button>
                      ) : null}
                    </div>
                  </>
                ) : null}
                {revealed !== undefined ? (
                  <pre className="max-h-72 overflow-auto border border-border bg-muted p-3 text-xs">
                    {formatJson(revealed)}
                  </pre>
                ) : null}
              </>
            ) : (
              <p className="text-sm text-muted-foreground">{t('console.no_settings')}</p>
            )}
          </CardContent>
        </Card>
      </div>
    </WorkspaceShell>
  )
}

function firstConfig(items: AppConfigurationItem[]): AppConfigurationItem | undefined {
  return items.find(item => item.editable) ?? items[0]
}
