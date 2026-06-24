import {
  RiArrowRightSLine,
  RiCloseLine,
  RiEyeLine,
  RiKey2Line,
  RiLogoutBoxRLine,
  RiRefreshLine,
  RiSave3Line,
  RiSettings3Line
} from '@remixicon/react'
import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Separator,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Textarea
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { apiErrorMessage } from '../common/api'
import {
  ankoleWebAppConfigurationControllerDecryptMutation,
  ankoleWebAppConfigurationControllerIndexOptions,
  ankoleWebAppConfigurationControllerIndexQueryKey,
  ankoleWebAppConfigurationControllerShowOptions,
  ankoleWebAppConfigurationControllerUpdateMutation,
  ankoleWebAppConfigurationControllerDeleteMutation
} from './api/generated/@tanstack/react-query.gen'
import type { AppConfigurationItem } from './api/generated/types.gen'
import { configureConsoleApiClient, logoutConsoleSession } from './api/tokens'

type DraftState = {
  error?: string
  text: string
}

/** Main web console application. */
export function ConsoleApp() {
  useMemo(() => configureConsoleApiClient(), [])

  const queryClient = useQueryClient()
  const list = useQuery(ankoleWebAppConfigurationControllerIndexOptions())
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const [draft, setDraft] = useState<DraftState>({ text: '' })
  const [revealed, setRevealed] = useState<unknown>(undefined)
  const items = list.data?.data ?? []
  const selectedFromList = selectedKey ? items.find(item => item.key === selectedKey) : undefined
  const selected = selectedFromList ?? firstSelectable(items)
  const detailEnabled = Boolean(selected?.editable && selected.key)
  const detail = useQuery({
    ...ankoleWebAppConfigurationControllerShowOptions({
      path: { key: selected?.key ?? '' }
    }),
    enabled: detailEnabled
  })
  const activeItem = detail.data?.data ?? selected

  const refreshList = () => {
    void queryClient.invalidateQueries({ queryKey: ankoleWebAppConfigurationControllerIndexQueryKey() })
    if (activeItem?.key) {
      void queryClient.invalidateQueries({
        predicate: query =>
          (query.queryKey[0] as { _id?: string } | undefined)?._id?.includes('AppConfiguration') ?? false
      })
    }
  }

  const update = useMutation({
    ...ankoleWebAppConfigurationControllerUpdateMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refreshList()
    }
  })
  const reset = useMutation({
    ...ankoleWebAppConfigurationControllerDeleteMutation(),
    onSuccess: response => {
      setRevealed(undefined)
      setSelectedKey(response.data.key)
      refreshList()
    }
  })
  const decrypt = useMutation({
    ...ankoleWebAppConfigurationControllerDecryptMutation(),
    onSuccess: response => setRevealed(response.data.value)
  })
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  useEffect(() => {
    if (!selectedKey && selected?.key) setSelectedKey(selected.key)
  }, [selected?.key, selectedKey])

  useEffect(() => {
    setRevealed(undefined)
    setDraft({ text: draftText(activeItem) })
  }, [activeItem?.key, activeItem?.source, activeItem?.value])

  const submitDraft = () => {
    if (!activeItem) return

    try {
      update.mutate({
        body: { value: JSON.parse(draft.text) },
        path: { key: activeItem.key }
      })
    } catch (error) {
      setDraft(current => ({ ...current, error: apiErrorMessage(error) }))
    }
  }

  return (
    <main className="min-h-screen bg-background text-foreground">
      <header className="flex min-h-16 items-center justify-between border-b border-border px-5">
        <div className="flex min-w-0 items-center gap-3">
          <div className="grid size-9 place-items-center border border-border bg-muted">
            <RiSettings3Line className="size-4" aria-hidden />
          </div>
          <div className="min-w-0">
            <h1 className="truncate text-base font-semibold tracking-normal">Ankole Console</h1>
            <p className="truncate text-xs text-muted-foreground">Control plane</p>
          </div>
        </div>
        <Button
          aria-label="Sign out"
          disabled={logout.isPending}
          size="icon-sm"
          type="button"
          variant="ghost"
          onClick={() => logout.mutate()}>
          <RiLogoutBoxRLine />
        </Button>
      </header>

      <div className="grid min-h-[calc(100vh-4rem)] grid-cols-1 lg:grid-cols-[240px_minmax(0,1fr)]">
        <aside className="border-b border-border bg-muted/35 p-3 lg:border-r lg:border-b-0">
          <nav className="grid gap-1" aria-label="Console sections">
            <button className="flex h-10 items-center gap-3 border border-primary bg-primary px-3 text-left text-sm text-primary-foreground">
              <RiKey2Line className="size-4" aria-hidden />
              <span className="truncate">AppConfigure</span>
              <RiArrowRightSLine className="ml-auto size-4" aria-hidden />
            </button>
          </nav>
        </aside>

        <section className="grid min-w-0 grid-cols-1 xl:grid-cols-[minmax(0,1.05fr)_minmax(420px,0.95fr)]">
          <div className="min-w-0 border-b border-border p-5 xl:border-r xl:border-b-0">
            <div className="mb-4 flex items-center justify-between gap-3">
              <h2 className="text-lg font-semibold tracking-normal">AppConfigure</h2>
              <Button size="icon-sm" variant="outline" type="button" aria-label="Refresh" onClick={() => refreshList()}>
                <RiRefreshLine />
              </Button>
            </div>
            <ErrorBlock error={list.error} />
            <ConfigTable
              items={items}
              loading={list.isLoading}
              selectedKey={activeItem?.key ?? null}
              onSelect={item => setSelectedKey(item.key)}
            />
          </div>

          <div className="min-w-0 p-5">
            {activeItem ? (
              <ConfigDetail
                decrypting={decrypt.isPending}
                draft={draft}
                item={activeItem}
                mutationError={update.error ?? reset.error ?? decrypt.error}
                revealed={revealed}
                resetting={reset.isPending}
                saving={update.isPending}
                onDraftChange={text => setDraft({ text })}
                onDecrypt={() => decrypt.mutate({ path: { key: activeItem.key } })}
                onReset={() => reset.mutate({ path: { key: activeItem.key } })}
                onSave={submitDraft}
              />
            ) : (
              <Card>
                <CardContent className="py-10 text-sm text-muted-foreground">
                  {list.isLoading ? 'Loading...' : 'No console-visible settings.'}
                </CardContent>
              </Card>
            )}
          </div>
        </section>
      </div>
    </main>
  )
}

function ConfigTable({
  items,
  loading,
  onSelect,
  selectedKey
}: {
  items: AppConfigurationItem[]
  loading: boolean
  onSelect: (item: AppConfigurationItem) => void
  selectedKey: string | null
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Key</TableHead>
          <TableHead>Kind</TableHead>
          <TableHead>Source</TableHead>
          <TableHead className="text-right">State</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.map(item => (
          <TableRow
            key={`${item.kind}:${item.key}`}
            data-state={selectedKey === item.key ? 'selected' : undefined}
            className="cursor-pointer"
            onClick={() => onSelect(item)}>
            <TableCell className="max-w-[320px] whitespace-normal font-mono text-xs text-foreground">
              {item.key}
            </TableCell>
            <TableCell>
              <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
            </TableCell>
            <TableCell>{item.source}</TableCell>
            <TableCell className="text-right">
              <div className="flex justify-end gap-2">
                {item.encrypted ? <Badge variant="destructive">encrypted</Badge> : null}
                {item.overridden ? <Badge>global</Badge> : null}
              </div>
            </TableCell>
          </TableRow>
        ))}
        {!loading && items.length === 0 ? (
          <TableRow>
            <TableCell colSpan={4} className="text-muted-foreground">
              No settings.
            </TableCell>
          </TableRow>
        ) : null}
      </TableBody>
    </Table>
  )
}

function ConfigDetail({
  decrypting,
  draft,
  item,
  mutationError,
  onDecrypt,
  onDraftChange,
  onReset,
  onSave,
  revealed,
  resetting,
  saving
}: {
  decrypting: boolean
  draft: DraftState
  item: AppConfigurationItem
  mutationError: unknown
  onDecrypt: () => void
  onDraftChange: (text: string) => void
  onReset: () => void
  onSave: () => void
  revealed: unknown
  resetting: boolean
  saving: boolean
}) {
  const editable = item.editable

  return (
    <Card className="rounded-none">
      <CardHeader>
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <CardTitle className="break-all font-mono text-base tracking-normal">{item.key}</CardTitle>
            <div className="mt-2 flex flex-wrap gap-2">
              <Badge variant={item.kind === 'pattern' ? 'outline' : 'secondary'}>{item.kind}</Badge>
              <Badge variant="outline">{item.source}</Badge>
              {item.encrypted ? <Badge variant="destructive">encrypted</Badge> : null}
            </div>
          </div>
          {editable ? (
            <Button
              aria-label="Reset"
              disabled={resetting}
              size="icon-sm"
              type="button"
              variant="outline"
              onClick={onReset}>
              <RiCloseLine />
            </Button>
          ) : null}
        </div>
      </CardHeader>
      <CardContent className="grid gap-4">
        {item.description ? <p className="text-sm leading-6 text-muted-foreground">{item.description}</p> : null}
        {item.kind === 'pattern' && item.pattern ? (
          <pre className="overflow-auto border border-border bg-muted p-3 text-xs">{item.pattern}</pre>
        ) : null}
        <ErrorBlock error={draft.error ?? mutationError} />
        {editable ? (
          <>
            <Textarea
              className="min-h-56 font-mono text-xs"
              spellCheck={false}
              value={draft.text}
              onChange={event => onDraftChange(event.target.value)}
            />
            <div className="flex flex-wrap items-center gap-2">
              <Button disabled={saving} size="sm" type="button" onClick={onSave}>
                <RiSave3Line data-icon="inline-start" />
                Save
              </Button>
              {item.encrypted ? (
                <Button disabled={decrypting} size="sm" type="button" variant="outline" onClick={onDecrypt}>
                  <RiEyeLine data-icon="inline-start" />
                  Reveal
                </Button>
              ) : null}
            </div>
          </>
        ) : null}
        {revealed !== undefined ? (
          <>
            <Separator />
            <pre className="max-h-72 overflow-auto border border-border bg-muted p-3 text-xs">
              {formatValue(revealed)}
            </pre>
          </>
        ) : null}
      </CardContent>
    </Card>
  )
}

function ErrorBlock({ error }: { error: unknown }) {
  if (!error) return null

  return (
    <div className="border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
      {apiErrorMessage(error)}
    </div>
  )
}

function firstSelectable(items: AppConfigurationItem[]): AppConfigurationItem | undefined {
  return items.find(item => item.editable) ?? items[0]
}

function draftText(item: AppConfigurationItem | undefined): string {
  if (!item) return ''
  if (item.encrypted && item.value === undefined) return '{}'
  return formatValue(item.value ?? null)
}

function formatValue(value: unknown): string {
  return JSON.stringify(value, null, 2)
}
