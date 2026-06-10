import { RiDashboardLine } from '@remixicon/react'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { apiErrorMessage } from '@/lib/api'
import type { ConsoleAgent } from '@/console/service'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Card, CardContent } from '@/uikit/components/card'
import { Empty, EmptyHeader, EmptyMedia, EmptyTitle } from '@/uikit/components/empty'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Skeleton } from '@/uikit/components/skeleton'
import { Table, TableBody, TableHead, TableHeader, TableRow } from '@/uikit/components/table'

export function SectionHeader({ title, description }: { title: string; description: string }) {
  return (
    <header className="flex flex-col gap-1">
      <h1 className="font-heading text-2xl leading-8">{title}</h1>
      <p className="max-w-3xl text-sm text-muted-foreground">{description}</p>
    </header>
  )
}

export function ErrorAlert({ error, title }: { error?: unknown; title: string }) {
  if (!error) return null

  return (
    <Alert variant="destructive">
      <AlertTitle>{title}</AlertTitle>
      <AlertDescription>
        <pre className="whitespace-pre-wrap text-xs">{apiErrorMessage(error)}</pre>
      </AlertDescription>
    </Alert>
  )
}

export function SkeletonRows({ rows }: { rows: number }) {
  return (
    <div className="grid gap-3">
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton key={index} className="h-10 w-full" />
      ))}
    </div>
  )
}

export function MetricCard({ label, value }: { label: string; value: number | undefined }) {
  return (
    <Card size="sm">
      <CardContent className="flex flex-col gap-2">
        <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">{label}</span>
        {value === undefined ? (
          <Skeleton className="h-7 w-16" />
        ) : (
          <span className="text-2xl font-semibold">{value}</span>
        )}
      </CardContent>
    </Card>
  )
}

export function TableCard({
  loading,
  error,
  empty,
  columns,
  children
}: {
  loading: boolean
  error: unknown
  empty: boolean
  columns: string[]
  children: ReactNode
}) {
  const { t } = useTranslation()
  if (loading) return <SkeletonRows rows={5} />
  if (error) return <ErrorAlert error={error} title={t('console.resource_load_failed')} />
  if (empty) {
    return (
      <Empty className="border border-dashed border-border p-8">
        <EmptyHeader>
          <EmptyMedia variant="icon">
            <RiDashboardLine />
          </EmptyMedia>
          <EmptyTitle>{t('console.no_records')}</EmptyTitle>
        </EmptyHeader>
      </Empty>
    )
  }

  return (
    <div className="border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            {columns.map((column, index) => (
              <TableHead
                key={column}
                className={index === columns.length - 1 && column === t('console.actions') ? 'text-right' : undefined}>
                {column}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>{children}</TableBody>
      </Table>
    </div>
  )
}

export function AgentSelector({
  agents,
  value,
  onChange
}: {
  agents: ConsoleAgent[]
  value: string
  onChange(uid: string): void
}) {
  const { t } = useTranslation()
  return (
    <div className="flex max-w-sm flex-col gap-2">
      <span className="text-xs font-medium tracking-wider text-muted-foreground uppercase">
        {t('console.agent_label')}
      </span>
      <Select value={value} onValueChange={next => onChange(next ?? value)}>
        <SelectTrigger className="w-full">
          <SelectValue placeholder={t('console.select_agent')} />
        </SelectTrigger>
        <SelectContent>
          {agents.map(agent => (
            <SelectItem key={agent.uid} value={agent.uid}>
              {agent.uid}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
