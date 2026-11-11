import { TableRow, useQuery, useSearchParams } from '../tenant-context'
import {
  Button,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader
} from '@ankole/uikit'
import { useId, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { getAiGatewayUsageOptions } from '../api/v2/generated/@tanstack/react-query.gen'
import type { GetAiGatewayUsageResponse } from '../api/v2/generated/types.gen'
import { ErrorBlock } from '../../common/error-block'
import { PageHeader, PageStack } from '../console-page'

type UsageRow = GetAiGatewayUsageResponse['total']
type CapabilityRow = GetAiGatewayUsageResponse['by_capability'][number]

const WINDOWS = ['7', '30'] as const

/**
 * One tenant's model usage over a recent window: tokens by Agent, by Human,
 * and by origin, and what the calls of every other capability produced.
 */
export function AIUsagePage() {
  const { t } = useTranslation()
  const [params, setParams] = useSearchParams()
  const days = WINDOWS.find(value => value === params.get('days')) ?? '7'
  const usage = useQuery(getAiGatewayUsageOptions({ query: { days: Number(days) } }))
  const setDays = (value: string) => {
    const next = new URLSearchParams(params)
    next.set('days', value)
    setParams(next)
  }

  return (
    <PageStack>
      <PageHeader
        title={t('console.ai_usage.title')}
        description={t('console.ai_usage.description')}
        actions={
          <Select value={days} onValueChange={value => setDays(String(value))}>
            <SelectTrigger aria-label={t('console.ai_usage.window')} className="min-w-40">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {WINDOWS.map(value => (
                <SelectItem key={value} value={value}>
                  {t('console.ai_usage.last_days', { count: Number(value) })}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        }
      />
      <ErrorBlock error={usage.error} />
      {usage.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : usage.data?.total.rounds === 0 && usage.data.by_capability.length === 0 ? (
        // One empty state for the whole window, whose next step is the longer window.
        <div className="grid justify-items-start gap-3 border border-border bg-card p-6">
          <p className="text-sm text-pretty text-muted-foreground">{t('console.ai_usage.empty')}</p>
          {days === '7' && (
            <Button variant="outline" size="sm" onClick={() => setDays('30')}>
              {t('console.ai_usage.show_longer')}
            </Button>
          )}
        </div>
      ) : usage.data ? (
        <>
          <UsageTable
            title={t('console.ai_usage.total')}
            rows={[usage.data.total]}
            label={() => t('console.ai_usage.all_work')}
          />
          <UsageTable
            title={t('console.ai_usage.by_agent')}
            rows={usage.data.by_agent}
            label={row => <PrincipalName row={row} />}
          />
          <UsageTable
            title={t('console.ai_usage.by_human')}
            rows={usage.data.by_human}
            label={row => (row.key ? <PrincipalName row={row} /> : t('console.ai_usage.no_human'))}
          />
          <UsageTable
            title={t('console.ai_usage.by_origin')}
            rows={usage.data.by_origin}
            label={row => t(`console.ai_usage.origin_${row.key}`, { defaultValue: row.key ?? '—' })}
          />
          <CapabilityTable rows={usage.data.by_capability} />
        </>
      ) : null}
    </PageStack>
  )
}

// The display name leads; the uid follows because it is unique within the tenant.
function PrincipalName({ row }: { row: UsageRow }) {
  return (
    <span className="grid min-w-0">
      <span className="truncate">{row.name ?? row.key}</span>
      {row.name && <span className="truncate font-mono text-xs text-muted-foreground">{row.key}</span>}
    </span>
  )
}

// Calls that are not language-model rounds count pages, seconds, characters,
// or images instead of tokens, so they have their own table.
export function CapabilityTable({ rows }: { rows: CapabilityRow[] }) {
  const { t, i18n } = useTranslation()
  const number = new Intl.NumberFormat(i18n.language)
  const cost = new Intl.NumberFormat(i18n.language, { maximumFractionDigits: 6 })
  const titleID = useId()

  return (
    <section className="grid min-w-0 gap-3">
      <div className="grid gap-1">
        <h3 id={titleID} className="title-section">
          {t('console.ai_usage.by_capability')}
        </h3>
        <p className="text-sm text-pretty text-muted-foreground">{t('console.ai_usage.by_capability_description')}</p>
      </div>
      {rows.length === 0 ? (
        <p className="border border-border bg-card p-6 text-sm text-muted-foreground">
          {t('console.ai_usage.by_capability_empty')}
        </p>
      ) : (
        <div className="overflow-x-auto border border-border bg-card">
          <Table aria-labelledby={titleID} className="min-w-[640px]">
            <TableHeader>
              <TableRow>
                <TableHead>{t('console.ai_usage.capability')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.calls')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.quantity')}</TableHead>
                <TableHead>{t('console.ai_usage.unit')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.reported_cost')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map(row => (
                <TableRow key={`${row.capability}:${row.unit ?? ''}`}>
                  <TableCell>
                    {t(`console.ai_usage.capability_${row.capability}`, { defaultValue: row.capability })}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{number.format(row.calls)}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.quantity == null ? '—' : number.format(row.quantity)}
                  </TableCell>
                  <TableCell>
                    {row.unit ? t(`console.ai_usage.unit_${row.unit}`, { defaultValue: row.unit }) : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {row.provider_cost == null ? '—' : cost.format(row.provider_cost)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </section>
  )
}

export function UsageTable({
  title,
  rows,
  label
}: {
  title: string
  rows: UsageRow[]
  label: (row: UsageRow) => ReactNode
}) {
  const { t, i18n } = useTranslation()
  const number = new Intl.NumberFormat(i18n.language)
  const count = (value?: number | null) => (value == null ? '—' : number.format(value))
  const titleID = useId()

  return (
    <section className="grid min-w-0 gap-3">
      <h3 id={titleID} className="title-section">
        {title}
      </h3>
      {rows.length === 0 ? (
        <p className="border border-border bg-card p-6 text-sm text-muted-foreground">{t('console.ai_usage.empty')}</p>
      ) : (
        <div className="overflow-x-auto border border-border bg-card">
          <Table aria-labelledby={titleID} className="min-w-[640px]">
            <TableHeader>
              <TableRow>
                <TableHead>{t('console.ai_usage.name')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.reported')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.input')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.output')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.cached')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.cache_write')}</TableHead>
                <TableHead className="text-right">{t('console.ai_usage.reasoning')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map(row => (
                <TableRow key={row.key ?? ''}>
                  <TableCell className="max-w-64">{label(row)}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {t('console.ai_usage.coverage', {
                      reported: number.format(row.reported_rounds),
                      rounds: number.format(row.rounds)
                    })}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{count(row.input_tokens)}</TableCell>
                  <TableCell className="text-right tabular-nums">{count(row.output_tokens)}</TableCell>
                  <TableCell className="text-right tabular-nums">{count(row.cached_input_tokens)}</TableCell>
                  <TableCell className="text-right tabular-nums">{count(row.cache_creation_input_tokens)}</TableCell>
                  <TableCell className="text-right tabular-nums">{count(row.reasoning_tokens)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </section>
  )
}
