import {
  Button,
  Input,
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectItem,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import { Link } from '@tanstack/react-router'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { SubpageItem } from './content-api'
import { PageIcon } from './page-icon'
import { usePageHref } from './use-page-metadata'
import { propertyText } from './state/knowledge-draft'
import { KnowledgeValue } from './knowledge-value'

/** Only authorized child pages reach this view. The columns come from their business metadata. */
export function KnowledgeTable({ pages }: { pages: SubpageItem[] }) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const [field, setField] = useState('')
  const [filter, setFilter] = useState('')
  const [sort, setSort] = useState<{ field: string; direction: number }>({ field: '', direction: 1 })
  const fields = [...new Set(pages.flatMap(page => Object.keys(page.metadata ?? {})))].sort()
  const rows = pages
    .filter(page => {
      const values = field ? [page.metadata?.[field]] : [page.title, ...Object.values(page.metadata ?? {})]
      return values.some(value => propertyText(value).toLocaleLowerCase().includes(filter.toLocaleLowerCase()))
    })
    .sort((a, b) => {
      const left = sort.field ? a.metadata?.[sort.field] : a.title
      const right = sort.field ? b.metadata?.[sort.field] : b.title
      const order =
        typeof left === 'number' && typeof right === 'number'
          ? left - right
          : propertyText(left).localeCompare(propertyText(right), undefined, { numeric: true })
      return order * sort.direction
    })
  const heading = (name: string, title: string) => (
    <TableHead
      key={name}
      scope="col"
      aria-sort={sort.field === name ? (sort.direction === 1 ? 'ascending' : 'descending') : 'none'}>
      <Button
        variant="ghost"
        size="sm"
        onClick={() =>
          setSort(current => ({ field: name, direction: current.field === name ? -current.direction : 1 }))
        }>
        {title}
        {sort.field === name && <span aria-hidden>{sort.direction === 1 ? '↑' : '↓'}</span>}
      </Button>
    </TableHead>
  )
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Select value={field} onValueChange={value => setField(value ?? '')}>
          <SelectTrigger aria-label={t('pod.knowledge.filter_property')} className="h-8 w-auto min-w-36">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="">{t('pod.knowledge.all_properties')}</SelectItem>
            {fields.map(field => (
              <SelectItem key={field} value={field}>
                {field}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Input
          className="max-w-xs"
          aria-label={t('pod.knowledge.filter_value')}
          placeholder={t('pod.knowledge.filter_value')}
          value={filter}
          onChange={event => setFilter(event.target.value)}
        />
      </div>
      <Table containerLabel={t('pod.knowledge.properties_table')}>
        <caption className="sr-only">{t('pod.knowledge.properties_table')}</caption>
        <TableHeader>
          <TableRow>
            {heading('', t('pod.subpages.field_name'))}
            {fields.map(field => heading(field, field))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map(page => (
            <TableRow key={page.id}>
              <TableCell className="min-w-48">
                <Link
                  data-row-link
                  className="inline-flex items-center gap-2 text-foreground underline underline-offset-2"
                  to={pageHref(page.id, page.title)}>
                  <PageIcon page={page} />
                  {page.title || t('pod.content.untitled')}
                </Link>
              </TableCell>
              {fields.map(field => (
                <TableCell key={field} className="max-w-sm whitespace-pre-wrap break-words">
                  <KnowledgeValue value={page.metadata?.[field]} />
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
      {!rows.length && <p className="text-sm text-fg-tertiary">{t('pod.content.no_pages_you_can_view_were_found')}</p>}
    </div>
  )
}
