import {
  buttonVariants,
  Checkbox,
  CopyButton,
  Input,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow
} from '@ankole/uikit'
import { useTranslation } from 'react-i18next'
import { DeclarativeFields } from './fields'
import { formatIdentifierLabel, isRecord } from './transport'
import { isSensitiveField, type DeclarativeFieldDescriptor, type WizardBlock, type WizardDataTableBlock } from './types'

function assertNever(value: never): never {
  throw new Error(`Unhandled wizard block: ${JSON.stringify(value)}`)
}

export function redactUrlCredentials(rawUrl: string): string {
  try {
    const parsed = new URL(rawUrl)
    if (!parsed.username && !parsed.password) return parsed.href
    return `${parsed.protocol}//***@${parsed.host}${parsed.pathname}${parsed.search}${parsed.hash}`
  } catch {
    return rawUrl.replace(/\/\/[^/@\s]+@/, '//***@')
  }
}

function sanitizeDisplayString(value: string): string {
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
    return redactUrlCredentials(value)
  }
  return value.replace(/\b[a-z][a-z0-9+.-]*:\/\/[^/\s:@]+(?::[^/\s@]+)?@/gi, match => {
    const schemeEnd = match.indexOf('://')
    return `${match.slice(0, schemeEnd)}://***@`
  })
}

function formatDisplayValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return '-'
  if (typeof value === 'string') return sanitizeDisplayString(value)
  if (typeof value === 'boolean' || typeof value === 'number') return String(value)
  if (Array.isArray(value)) return value.map(item => formatDisplayValue(item)).join(', ')
  return (
    JSON.stringify(value, (_key, nested) => (typeof nested === 'string' ? sanitizeDisplayString(nested) : nested)) ?? ''
  )
}

function readTableRows(state: Readonly<Record<string, unknown>>, rowsField: string): Record<string, unknown>[] {
  const raw = state[rowsField]
  return Array.isArray(raw) ? raw.filter(isRecord) : []
}

export function selectedRowIds(state: Readonly<Record<string, unknown>>, fieldName: string): string[] {
  const raw = state[fieldName]
  return Array.isArray(raw) ? raw.filter((item): item is string => typeof item === 'string' && item !== '') : []
}

export function canBlockAdvance(block: WizardBlock, state: Readonly<Record<string, unknown>>): boolean {
  switch (block.kind) {
    case 'fields':
    case 'external_link':
    case 'summary':
      return true
    case 'data_table':
      return block.selection === undefined || selectedRowIds(state, block.selection.field).length > 0
    default:
      return assertNever(block)
  }
}

export function toggleTableSelectionRow(
  state: Readonly<Record<string, unknown>>,
  block: WizardDataTableBlock,
  rowId: string,
  checked: boolean
): Record<string, unknown> {
  const selection = block.selection
  if (!selection) return { ...state }

  const rows = readTableRows(state, block.rowsField)
  const target = rows.find(row => row[selection.rowKeyField] === rowId)
  if (!target) return { ...state }
  if (selection.selectableField && target[selection.selectableField] === false) {
    return { ...state }
  }

  const nextSelected = new Set(selectedRowIds(state, selection.field))
  if (checked) nextSelected.add(rowId)
  else nextSelected.delete(rowId)

  const orderedIds: string[] = []
  for (const row of rows) {
    const key = row[selection.rowKeyField]
    if (typeof key === 'string' && nextSelected.has(key)) {
      orderedIds.push(key)
    }
  }
  return { ...state, [selection.field]: orderedIds }
}

function ExternalLinkBlockView({
  url,
  openLabelKey,
  urlField
}: {
  url: unknown
  openLabelKey: string
  urlField: string
}) {
  const { t } = useTranslation()
  if (typeof url !== 'string' || url.length === 0) return null
  const label = t(openLabelKey, { defaultValue: 'Open authorization page' })

  return (
    <div className="grid gap-2">
      <Input aria-label={formatIdentifierLabel(urlField)} className="font-mono text-xs" readOnly value={url} />
      <div className="flex flex-wrap items-center gap-2">
        <CopyButton
          copiedLabel={t('common.copied', { defaultValue: 'Copied' })}
          label={t('common.copy', { defaultValue: 'Copy URL' })}
          value={url}
        />
        <a
          className={buttonVariants({ variant: 'outline', size: 'sm' })}
          href={url}
          rel="noopener noreferrer"
          target="_blank">
          {label}
        </a>
      </div>
    </div>
  )
}

function DataTableBlockView({
  block,
  state,
  sensitiveFieldNames,
  i18nPrefix,
  onStateChange
}: {
  block: WizardDataTableBlock
  state: Readonly<Record<string, unknown>>
  sensitiveFieldNames: ReadonlySet<string>
  i18nPrefix: string
  onStateChange: (updater: (prev: Record<string, unknown>) => Record<string, unknown>) => void
}) {
  const { t } = useTranslation()
  const rawRows = readTableRows(state, block.rowsField)
  const filterConfig = block.filterBySelection
  const visibleRows = filterConfig
    ? (() => {
        const allowed = new Set(selectedRowIds(state, filterConfig.field))
        return rawRows.filter(row => {
          const key = row[filterConfig.rowKeyField]
          return typeof key === 'string' && allowed.has(key)
        })
      })()
    : rawRows

  const selection = block.selection
  const selectedSet = new Set(selection ? selectedRowIds(state, selection.field) : [])
  const visibleColumns = block.columns.filter(column => !sensitiveFieldNames.has(column))

  if (visibleColumns.length === 0 && !selection) return null

  return (
    <div className="overflow-x-auto border border-border-subtle">
      <Table>
        <TableHeader>
          <TableRow>
            {selection ? <TableHead>{t(`${i18nPrefix}.ui.select_row`, { defaultValue: 'Select' })}</TableHead> : null}
            {visibleColumns.map(column => (
              <TableHead key={column}>
                {t(`${i18nPrefix}.field.${column}`, { defaultValue: formatIdentifierLabel(column) })}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {visibleRows.map((row, index) => {
            const rawKey = selection ? row[selection.rowKeyField] : undefined
            const rowId = typeof rawKey === 'string' && rawKey !== '' ? rawKey : undefined
            const selectable =
              selection !== undefined &&
              rowId !== undefined &&
              (selection.selectableField === undefined || row[selection.selectableField] !== false)
            return (
              <TableRow key={rowId ?? index}>
                {selection ? (
                  <TableCell>
                    <Checkbox
                      aria-label={t(`${i18nPrefix}.ui.select_row_number`, {
                        defaultValue: 'Select row {{number}}',
                        number: index + 1
                      })}
                      checked={rowId !== undefined && selectedSet.has(rowId)}
                      disabled={!selectable}
                      onCheckedChange={checked => {
                        if (selectable && rowId !== undefined) {
                          onStateChange(prev => toggleTableSelectionRow(prev, block, rowId, checked === true))
                        }
                      }}
                    />
                  </TableCell>
                ) : null}
                {visibleColumns.map(column => (
                  <TableCell key={column}>{formatDisplayValue(row[column])}</TableCell>
                ))}
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </div>
  )
}

function SummaryBlockView({
  fields,
  state,
  sensitiveFieldNames,
  i18nPrefix
}: {
  fields: readonly string[]
  state: Readonly<Record<string, unknown>>
  sensitiveFieldNames: ReadonlySet<string>
  i18nPrefix: string
}) {
  const { t } = useTranslation()
  const visibleFields = fields.filter(name => !sensitiveFieldNames.has(name))
  if (visibleFields.length === 0) return null

  return (
    <dl className="divide-y divide-border-subtle rounded-md border border-border-subtle text-sm">
      {visibleFields.map(fieldName => (
        <div key={fieldName} className="grid gap-1 px-3 py-2 sm:grid-cols-[10rem_1fr]">
          <dt className="text-fg-secondary">
            {t(`${i18nPrefix}.field.${fieldName}`, { defaultValue: formatIdentifierLabel(fieldName) })}
          </dt>
          <dd className="break-all font-mono text-xs">{formatDisplayValue(state[fieldName])}</dd>
        </div>
      ))}
    </dl>
  )
}

export function WizardBlockRenderer({
  block,
  state,
  surfaceFields,
  disabled = false,
  i18nPrefix = 'console',
  onStateChange
}: {
  block: WizardBlock
  state: Readonly<Record<string, unknown>>
  surfaceFields: readonly DeclarativeFieldDescriptor[]
  disabled?: boolean
  i18nPrefix?: string
  onStateChange: (updater: (prev: Record<string, unknown>) => Record<string, unknown>) => void
}) {
  const sensitiveFieldNames = new Set(surfaceFields.filter(isSensitiveField).map(field => field.name))

  switch (block.kind) {
    case 'fields':
      return (
        <DeclarativeFields
          disabled={disabled}
          draft={{ ...state }}
          fields={block.fields}
          i18nPrefix={i18nPrefix}
          onChange={next => onStateChange(() => next)}
        />
      )
    case 'external_link':
      return (
        <ExternalLinkBlockView
          openLabelKey={block.openLabelKey}
          url={state[block.urlField]}
          urlField={block.urlField}
        />
      )
    case 'data_table':
      return (
        <DataTableBlockView
          block={block}
          i18nPrefix={i18nPrefix}
          sensitiveFieldNames={sensitiveFieldNames}
          state={state}
          onStateChange={onStateChange}
        />
      )
    case 'summary':
      return (
        <SummaryBlockView
          fields={block.fields}
          i18nPrefix={i18nPrefix}
          sensitiveFieldNames={sensitiveFieldNames}
          state={state}
        />
      )
    default:
      return assertNever(block)
  }
}
