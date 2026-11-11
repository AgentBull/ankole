import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
  Alert,
  AlertDescription,
  AlertTitle,
  AnkoleChart,
  AnkoleStatCard,
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  Progress,
  ProgressLabel,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
  ToggleGroup,
  ToggleGroupItem,
  type StatisticalChartSpec
} from '@ankole/uikit'
import { defineRegistry, useBoundProp } from '@json-render/react'
import { ArrowDownRegular, ArrowUpRegular } from '@ankole/uikit/icons'
import { useId, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { uiBlockCatalog } from './catalog'

type Cell = string | number | boolean | null
type Row = Record<string, Cell>

const GAPS = { sm: 'gap-2', md: 'gap-3', lg: 'gap-4' }
const COLUMNS: Record<number, string> = {
  2: '@md:grid-cols-2',
  3: '@md:grid-cols-3',
  4: '@md:grid-cols-2 @2xl:grid-cols-4'
}

function compareCells(left: Cell | undefined, right: Cell | undefined) {
  if (left == null || right == null) return left == null ? (right == null ? 0 : 1) : -1
  if (typeof left === 'number' && typeof right === 'number') return left - right
  return String(left).localeCompare(String(right), undefined, { numeric: true })
}

function DataTable({
  columns,
  rows,
  sortable
}: {
  columns: { key: string; label: string; align?: 'start' | 'end' | null }[]
  rows: Row[]
  sortable?: boolean | null
}) {
  const [sort, setSort] = useState<{ key: string; descending: boolean }>()
  const sorted = useMemo(() => {
    if (!sort) return rows
    // Empty cells stay last in both directions.
    return [...rows].sort((a, b) => {
      const order = compareCells(a[sort.key], b[sort.key])
      return a[sort.key] == null || b[sort.key] == null || !sort.descending ? order : -order
    })
  }, [rows, sort])
  return (
    <Table>
      <TableHeader>
        <TableRow>
          {columns.map(column => {
            const active = sort?.key === column.key
            const Arrow = active && sort.descending ? ArrowDownRegular : ArrowUpRegular
            return (
              <TableHead
                key={column.key}
                dir="auto"
                className={cn(column.align === 'end' && 'text-end')}
                aria-sort={active ? (sort.descending ? 'descending' : 'ascending') : undefined}>
                {sortable ? (
                  <button
                    type="button"
                    className="inline-flex items-center gap-1"
                    onClick={() => setSort({ key: column.key, descending: active && !sort.descending })}>
                    {column.label}
                    <Arrow aria-hidden className={cn('size-3.5', !active && 'opacity-0')} />
                  </button>
                ) : (
                  column.label
                )}
              </TableHead>
            )
          })}
        </TableRow>
      </TableHeader>
      <TableBody>
        {sorted.map((row, index) => (
          <TableRow key={index}>
            {columns.map(column => (
              <TableCell key={column.key} dir="auto" className={cn(column.align === 'end' && 'text-end tabular-nums')}>
                {row[column.key] == null ? '' : String(row[column.key])}
              </TableCell>
            ))}
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

function InlineChart(props: {
  type: StatisticalChartSpec['type']
  data: Row[]
  xField: string
  yField: string
  seriesField?: string | null
  title?: string | null
  stacked?: boolean | null
}) {
  const { t } = useTranslation()
  // The renderer resolves props on every render; the chart redraws only when their content changes.
  const content = JSON.stringify(props)
  const spec = useMemo<StatisticalChartSpec>(
    () => ({
      type: props.type,
      data: props.data,
      xField: props.xField,
      yField: props.yField,
      seriesField: props.seriesField ?? undefined,
      title: props.title ?? undefined,
      stackMode: props.stacked ? 'stacked' : undefined
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `content` covers every prop read above
    [content]
  )
  return (
    <AnkoleChart
      spec={spec}
      ariaLabel={props.title ?? props.yField}
      tableToggleLabel={t('pod.content.data_table', { defaultValue: 'Data table' })}
      height={260}
    />
  )
}

function Section({ title, children }: { title: string; children?: ReactNode }) {
  const value = useId()
  return (
    <AccordionItem value={value}>
      <AccordionTrigger className="py-2.5">{title}</AccordionTrigger>
      <AccordionContent>{children}</AccordionContent>
    </AccordionItem>
  )
}

export const { registry: uiBlockRegistry } = defineRegistry(uiBlockCatalog, {
  components: {
    Stack: ({ props, children }) => (
      <div
        className={cn(
          'flex',
          props.direction === 'horizontal' ? 'flex-row flex-wrap items-center' : 'flex-col',
          GAPS[props.gap ?? 'md']
        )}>
        {children}
      </div>
    ),
    Grid: ({ props, children }) => (
      <div className="@container">
        <div className={cn('grid gap-3', COLUMNS[props.columns])}>{children}</div>
      </div>
    ),
    Card: ({ props, children }) => (
      <Card size="sm">
        {(props.title || props.description) && (
          <CardHeader>
            {props.title && <CardTitle dir="auto">{props.title}</CardTitle>}
            {props.description && <CardDescription dir="auto">{props.description}</CardDescription>}
          </CardHeader>
        )}
        <CardContent>{children}</CardContent>
      </Card>
    ),
    Tabs: ({ props, children }) => (
      <Tabs defaultValue={props.tabs[0]?.value}>
        <TabsList>
          {props.tabs.map(tab => (
            <TabsTrigger key={tab.value} value={tab.value}>
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>
        {children}
      </Tabs>
    ),
    // A hidden panel stays mounted, so a table keeps its sort order while the reader looks at another tab.
    TabPanel: ({ props, children }) => (
      <TabsContent value={props.value} keepMounted>
        {children}
      </TabsContent>
    ),
    Accordion: ({ children }) => <Accordion>{children}</Accordion>,
    AccordionItem: ({ props, children }) => <Section title={props.title}>{children}</Section>,
    Text: ({ props }) => (
      <p
        dir="auto"
        className={cn(
          'text-sm',
          props.tone === 'secondary' && 'text-fg-secondary',
          props.weight === 'medium' && 'font-medium'
        )}>
        {props.text}
      </p>
    ),
    Badge: ({ props }) => <Badge variant={props.variant ?? 'secondary'}>{props.text}</Badge>,
    Stat: ({ props }) => (
      <AnkoleStatCard
        label={props.label}
        value={props.value}
        delta={props.delta}
        caption={props.caption}
        sparklineValues={props.sparkline ?? undefined}
      />
    ),
    Table: ({ props }) => <DataTable columns={props.columns} rows={props.rows} sortable={props.sortable} />,
    Chart: ({ props }) => <InlineChart {...props} />,
    Progress: ({ props }) => (
      <Progress value={props.value} aria-label={props.label ?? undefined}>
        {props.label && <ProgressLabel>{props.label}</ProgressLabel>}
      </Progress>
    ),
    Alert: ({ props }) => (
      <Alert variant={props.variant ?? 'default'}>
        {props.title && <AlertTitle dir="auto">{props.title}</AlertTitle>}
        <AlertDescription dir="auto">{props.text}</AlertDescription>
      </Alert>
    ),
    Button: ({ props, emit }) => (
      <Button size="sm" variant={props.variant ?? 'outline'} onClick={() => emit('press')}>
        {props.label}
      </Button>
    ),
    ToggleGroup: ({ props, bindings }) => {
      const [value, setValue] = useBoundProp<string>(
        typeof props.value === 'string' ? props.value : undefined,
        bindings?.value
      )
      return (
        <ToggleGroup
          size="sm"
          spacing={0}
          value={value ? [value] : []}
          onValueChange={next => {
            const chosen = next.at(-1)
            if (chosen) setValue(chosen)
          }}>
          {props.options.map(option => (
            <ToggleGroupItem key={option.value} value={option.value}>
              {option.label}
            </ToggleGroupItem>
          ))}
        </ToggleGroup>
      )
    }
  },
  // `UIBlock` passes the real `reply` handler to its provider, because a handler here cannot read React context.
  actions: { reply: async () => {} }
})
