import { Badge, Button, TableCell, TableRow, buttonVariants, cn, toast } from '@ankole/uikit'
import { RiEyeLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from 'react-router'
import {
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerDeleteMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerUpdateMutation
} from '../api/generated/@tanstack/react-query.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { formatJson, parseJson } from '../console-primitives'
import { JsonField, ResourceEditorPage, ResourceListPage } from '../console-shell'

export function SettingsListPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const items = list.data?.data ?? []

  return (
    <ResourceListPage
      title={t('console.settings.title')}
      description={t('console.settings.description')}
      columns={[
        t('console.settings.key'),
        t('console.settings.kind'),
        t('console.settings.source'),
        t('console.settings.state')
      ]}
      isLoading={list.isLoading}
      isEmpty={items.length === 0}
      emptyTitle={t('console.settings.empty_title')}
      emptyDescription={t('console.no_settings')}
      error={list.error}>
      {items.map(item => (
        <TableRow
          key={`${item.kind}:${item.key}`}
          className={item.editable ? 'cursor-pointer' : undefined}
          onClick={() => item.editable && navigate(encodeURIComponent(item.key))}>
          <TableCell className="max-w-[360px] font-mono text-xs break-all whitespace-normal">{item.key}</TableCell>
          <TableCell>
            <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
          </TableCell>
          <TableCell>{item.source}</TableCell>
          <TableCell>
            <div className="flex flex-wrap gap-1.5">
              {item.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
              {item.overridden ? <Badge>{t('console.status.global')}</Badge> : null}
            </div>
          </TableCell>
          <TableCell className="text-right">
            {item.editable ? (
              <Link
                to={encodeURIComponent(item.key)}
                onClick={event => event.stopPropagation()}
                className={cn(buttonVariants({ size: 'xs', variant: 'ghost' }))}>
                {t('common.edit')}
              </Link>
            ) : (
              <span className="pr-2 text-xs text-muted-foreground">{t('console.settings.read_only')}</span>
            )}
          </TableCell>
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function SettingEditorPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const params = useParams()
  const key = params.key ? decodeURIComponent(params.key) : ''

  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const summary = list.data?.data.find(item => item.key === key)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({ path: { key } }),
    enabled: Boolean(summary?.editable && key)
  })
  const item = detail.data?.data ?? summary

  const [text, setText] = useState('')
  const [error, setError] = useState<string>()
  const [revealed, setRevealed] = useState<unknown>(undefined)

  useEffect(() => {
    setRevealed(undefined)
    setText(formatJson(item?.encrypted && item.value === undefined ? {} : (item?.value ?? null)))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item?.key, item?.source, item?.value])

  const refresh = () => void queryClient.invalidateQueries()
  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => {
      toast.success(t('console.settings.saved', { key: response.data.key }))
      refresh()
      navigate('..')
    },
    onError: mutationError => setError(requestErrorMessage(mutationError))
  })
  const reset = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: () => {
      toast.success(t('console.settings.reset_done', { key }))
      setRevealed(undefined)
      refresh()
    },
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    onSuccess: response => setRevealed(response.data.value),
    onError: mutationError => toast.error(requestErrorMessage(mutationError))
  })

  const submit = () => {
    setError(undefined)
    if (!item) return
    const parsed = parseJson(text, 'value')
    if (!parsed.ok) {
      setError(parsed.error)
      return
    }
    update.mutate({ body: { value: parsed.value }, path: { key: item.key } })
  }

  return (
    <ResourceEditorPage
      title={key}
      description={item?.description ?? t('console.settings.editor_description')}
      backTo=".."
      error={error ?? update.error ?? decrypt.error}
      submitting={update.isPending}
      onSubmit={submit}
      secondary={
        item?.editable ? (
          <Button
            disabled={reset.isPending}
            size="sm"
            type="button"
            variant="outline"
            onClick={() => reset.mutate({ path: { key: item.key } })}>
            {t('console.settings.reset')}
          </Button>
        ) : null
      }>
      <div className="flex flex-wrap items-center gap-2">
        {item ? <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge> : null}
        {item ? <Badge variant="outline">{item.source}</Badge> : null}
        {item?.encrypted ? <Badge variant="destructive">{t('console.status.encrypted')}</Badge> : null}
      </div>

      <JsonField label={t('console.settings.value')} value={text} minRows={10} onChange={setText} />

      {item?.encrypted ? (
        <Button
          disabled={decrypt.isPending}
          size="sm"
          type="button"
          variant="outline"
          onClick={() => decrypt.mutate({ path: { key: item.key } })}>
          <RiEyeLine data-icon="inline-start" />
          {t('console.settings.reveal')}
        </Button>
      ) : null}

      {revealed !== undefined ? (
        <pre className="max-h-72 overflow-auto border border-border bg-muted p-3 text-xs">{formatJson(revealed)}</pre>
      ) : null}
    </ResourceEditorPage>
  )
}
