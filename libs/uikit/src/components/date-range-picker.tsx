'use client'

import { RiArrowLeftSLine, RiArrowRightSLine, RiCalendarLine, RiCloseLine } from '@remixicon/react'
import * as React from 'react'

import { cn } from '../lib/utils'
import { Badge } from './badge'
import { Button } from './button'
import { Popover, PopoverContent, PopoverTrigger } from './popover'

export type PlainCalendarDate = {
  year: number
  month: number
  day: number
}

export type DateRange = {
  from: string | null
  to: string | null
}

export type DateRangePreset = {
  label: string
  range: DateRange
}

export type DatePickerProps = {
  value?: string | null
  defaultValue?: string | null
  onValueChange?: (value: string | null) => void
  minDate?: string
  maxDate?: string
  placeholder?: string
  clearable?: boolean
  clearLabel?: string
  disabled?: boolean
  timezone?: string
  locale?: string
  id?: string
  'aria-label'?: string
  'aria-labelledby'?: string
  className?: string
}

export type DateRangePickerProps = {
  value?: DateRange
  defaultValue?: DateRange
  onValueChange?: (value: DateRange) => void
  presets?: readonly DateRangePreset[]
  minDate?: string
  maxDate?: string
  placeholder?: string
  clearable?: boolean
  clearLabel?: string
  disabled?: boolean
  timezone?: string
  locale?: string
  numberOfMonths?: 1 | 2
  id?: string
  'aria-label'?: string
  'aria-labelledby'?: string
  className?: string
}

const ISO_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/

export function daysInCalendarMonth(year: number, month: number): number {
  if (month < 1 || month > 12) return 0
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

/**
 * Parses a location-agnostic ISO calendar date (`YYYY-MM-DD`) without constructing
 * a local-timezone `Date`, avoiding off-by-one shifts west of UTC.
 */
export function parseISODate(iso: string | null | undefined): PlainCalendarDate | null {
  if (!iso) return null
  const match = ISO_DATE_RE.exec(iso.trim())
  if (!match) return null
  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  const maxDay = daysInCalendarMonth(year, month)
  if (year < 1 || maxDay === 0 || day < 1 || day > maxDay) return null
  return { year, month, day }
}

export function formatISODate(date: PlainCalendarDate): string {
  const yyyy = String(date.year).padStart(4, '0')
  const mm = String(date.month).padStart(2, '0')
  const dd = String(date.day).padStart(2, '0')
  return `${yyyy}-${mm}-${dd}`
}

export function compareISODate(a: string, b: string): number {
  return a === b ? 0 : a < b ? -1 : 1
}

export function addMonthsPlain(
  monthView: { year: number; month: number },
  delta: number
): { year: number; month: number } {
  const zeroIndexed = monthView.year * 12 + (monthView.month - 1) + delta
  const year = Math.floor(zeroIndexed / 12)
  const month = (((zeroIndexed % 12) + 12) % 12) + 1
  return { year, month }
}

export function todayISODate(timezone?: string): string {
  try {
    const parts = new Intl.DateTimeFormat('en-CA', {
      timeZone: timezone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit'
    }).formatToParts(new Date())
    const year = Number(parts.find(part => part.type === 'year')?.value)
    const month = Number(parts.find(part => part.type === 'month')?.value)
    const day = Number(parts.find(part => part.type === 'day')?.value)
    if (year && month && day) return formatISODate({ year, month, day })
  } catch {
    // Fall back to UTC calendar components when an unknown timezone identifier is supplied.
  }
  const now = new Date()
  return formatISODate({ year: now.getUTCFullYear(), month: now.getUTCMonth() + 1, day: now.getUTCDate() })
}

export function buildCalendarGrid(year: number, month: number): (PlainCalendarDate | null)[][] {
  const firstWeekday = new Date(Date.UTC(year, month - 1, 1)).getUTCDay()
  const totalDays = daysInCalendarMonth(year, month)
  const cells: (PlainCalendarDate | null)[] = Array.from({ length: firstWeekday }, () => null)
  for (let day = 1; day <= totalDays; day++) {
    cells.push({ year, month, day })
  }
  while (cells.length % 7 !== 0) cells.push(null)
  const weeks: (PlainCalendarDate | null)[][] = []
  for (let index = 0; index < cells.length; index += 7) {
    weeks.push(cells.slice(index, index + 7))
  }
  return weeks
}

export function applyDateRangeSelection(current: DateRange, clickedISO: string): DateRange {
  if (!current.from || (current.from && current.to)) {
    return { from: clickedISO, to: null }
  }
  if (compareISODate(clickedISO, current.from) < 0) {
    return { from: clickedISO, to: current.from }
  }
  return { from: current.from, to: clickedISO }
}

function isDateDisabled(iso: string, minDate?: string, maxDate?: string): boolean {
  if (minDate && compareISODate(iso, minDate) < 0) return true
  if (maxDate && compareISODate(iso, maxDate) > 0) return true
  return false
}

function clampISODate(iso: string, minDate?: string, maxDate?: string): string {
  if (minDate && compareISODate(iso, minDate) < 0) return minDate
  if (maxDate && compareISODate(iso, maxDate) > 0) return maxDate
  return iso
}

export function constrainDateRange(range: DateRange, minDate?: string, maxDate?: string): DateRange | null {
  let { from, to } = range
  if (from && to && compareISODate(from, to) > 0) {
    ;[from, to] = [to, from]
  }
  if (!from && !to) return { from: null, to: null }
  if (from && to) {
    if ((minDate && compareISODate(to, minDate) < 0) || (maxDate && compareISODate(from, maxDate) > 0)) {
      return null
    }
  } else if (from) {
    if (maxDate && compareISODate(from, maxDate) > 0) return null
  } else if (to) {
    if (minDate && compareISODate(to, minDate) < 0) return null
  }
  return {
    from: from ? clampISODate(from, minDate, maxDate) : null,
    to: to ? clampISODate(to, minDate, maxDate) : null
  }
}

function formatMonthHeading(year: number, month: number, locale?: string): string {
  return new Intl.DateTimeFormat(locale, {
    timeZone: 'UTC',
    year: 'numeric',
    month: 'short'
  }).format(new Date(Date.UTC(year, month - 1, 1)))
}

function weekdayHeaders(locale?: string): string[] {
  const formatter = new Intl.DateTimeFormat(locale, { timeZone: 'UTC', weekday: 'narrow' })
  // 2023-01-01 is a Sunday in UTC.
  return Array.from({ length: 7 }, (_, offset) => formatter.format(new Date(Date.UTC(2023, 0, 1 + offset))))
}

function CalendarMonth({
  year,
  month,
  locale,
  selectedSingle,
  range,
  today,
  minDate,
  maxDate,
  onSelect
}: {
  year: number
  month: number
  locale?: string
  selectedSingle?: string | null
  range?: DateRange
  today: string
  minDate?: string
  maxDate?: string
  onSelect: (iso: string) => void
}) {
  const weeks = React.useMemo(() => buildCalendarGrid(year, month), [year, month])
  const weekdays = React.useMemo(() => weekdayHeaders(locale), [locale])

  return (
    <div data-slot="calendar-month" className="grid gap-2">
      <div className="text-center text-xs font-semibold text-foreground">{formatMonthHeading(year, month, locale)}</div>
      <table role="grid" aria-label={formatMonthHeading(year, month, locale)} className="w-full border-collapse">
        <thead>
          <tr>
            {weekdays.map((dayLabel, index) => (
              <th
                key={index}
                scope="col"
                className="size-8 text-center text-[11px] font-medium text-muted-foreground select-none">
                {dayLabel}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {weeks.map((week, weekIndex) => (
            <tr key={weekIndex}>
              {week.map((cell, dayIndex) => {
                if (!cell) {
                  return <td key={dayIndex} className="size-8 p-0" />
                }
                const iso = formatISODate(cell)
                const disabled = isDateDisabled(iso, minDate, maxDate)
                const isSingle = selectedSingle === iso
                const isRangeStart = range?.from === iso
                const isRangeEnd = range?.to === iso
                const isInRange =
                  !!range?.from &&
                  !!range?.to &&
                  compareISODate(iso, range.from) > 0 &&
                  compareISODate(iso, range.to) < 0
                const isSelected = isSingle || isRangeStart || isRangeEnd
                const isToday = iso === today
                return (
                  <td key={iso} className="p-0 text-center">
                    <button
                      type="button"
                      disabled={disabled}
                      aria-label={iso}
                      aria-pressed={isSelected}
                      onClick={() => onSelect(iso)}
                      className={cn(
                        'inline-flex size-8 cursor-pointer items-center justify-center rounded-control text-xs tabular-nums transition-colors focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none disabled:cursor-not-allowed disabled:opacity-35',
                        isSelected
                          ? 'bg-primary font-medium text-primary-foreground'
                          : isInRange
                            ? 'rounded-none bg-accent text-accent-foreground hover:bg-accent/80'
                            : 'text-foreground hover:bg-muted',
                        isToday && !isSelected && 'font-semibold underline decoration-primary underline-offset-4'
                      )}>
                      {cell.day}
                    </button>
                  </td>
                )
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function initialMonthFor(isoCandidates: (string | null | undefined)[], timezone?: string) {
  for (const candidate of isoCandidates) {
    const parsed = parseISODate(candidate)
    if (parsed) return { year: parsed.year, month: parsed.month }
  }
  const today = parseISODate(todayISODate(timezone))!
  return { year: today.year, month: today.month }
}

export function DatePicker({
  value,
  defaultValue = null,
  onValueChange,
  minDate,
  maxDate,
  placeholder = 'YYYY-MM-DD',
  clearable = true,
  clearLabel = 'Clear date',
  disabled = false,
  timezone,
  locale,
  id,
  'aria-label': ariaLabel,
  'aria-labelledby': ariaLabelledBy,
  className
}: DatePickerProps) {
  const controlled = value !== undefined
  const [uncontrolled, setUncontrolled] = React.useState<string | null>(defaultValue)
  const selected = controlled ? (value ?? null) : uncontrolled
  const [open, setOpen] = React.useState(false)
  const today = React.useMemo(() => todayISODate(timezone), [timezone])
  const [monthView, setMonthView] = React.useState(() => initialMonthFor([selected, minDate], timezone))

  const update = (next: string | null) => {
    if (!controlled) setUncontrolled(next)
    onValueChange?.(next)
  }

  return (
    <div data-slot="date-picker" className={cn('inline-flex items-center gap-1', className)}>
      <Popover
        open={open}
        onOpenChange={next => {
          if (disabled && next) return
          if (next) setMonthView(initialMonthFor([selected, minDate], timezone))
          setOpen(next)
        }}>
        <PopoverTrigger
          id={id}
          disabled={disabled}
          aria-label={ariaLabel}
          aria-labelledby={ariaLabelledBy}
          render={
            <Button type="button" variant="outline" size="default" className="justify-between gap-2 font-normal" />
          }>
          <RiCalendarLine aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
          <span className={cn('tabular-nums', !selected && 'text-fg-placeholder')}>{selected ?? placeholder}</span>
          {timezone && (
            <Badge variant="secondary" className="ml-1 px-1.5 py-0 text-[10px] font-normal">
              {timezone}
            </Badge>
          )}
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto min-w-64 gap-3 p-3">
          <div className="flex items-center justify-between gap-2">
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label="Previous month"
              onClick={() => setMonthView(prev => addMonthsPlain(prev, -1))}>
              <RiArrowLeftSLine aria-hidden="true" className="size-4" />
            </Button>
            <span className="text-xs text-muted-foreground">{timezone ?? 'ISO 8601'}</span>
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label="Next month"
              onClick={() => setMonthView(prev => addMonthsPlain(prev, 1))}>
              <RiArrowRightSLine aria-hidden="true" className="size-4" />
            </Button>
          </div>
          <CalendarMonth
            year={monthView.year}
            month={monthView.month}
            locale={locale}
            selectedSingle={selected}
            today={today}
            minDate={minDate}
            maxDate={maxDate}
            onSelect={iso => {
              update(iso)
              setOpen(false)
            }}
          />
        </PopoverContent>
      </Popover>
      {clearable && selected && !disabled && (
        <Button type="button" variant="ghost" size="icon-xs" aria-label={clearLabel} onClick={() => update(null)}>
          <RiCloseLine aria-hidden="true" className="size-3.5" />
        </Button>
      )}
    </div>
  )
}

export function DateRangePicker({
  value,
  defaultValue = { from: null, to: null },
  onValueChange,
  presets,
  minDate,
  maxDate,
  placeholder = 'YYYY-MM-DD – YYYY-MM-DD',
  clearable = true,
  clearLabel = 'Clear date range',
  disabled = false,
  timezone,
  locale,
  numberOfMonths = 2,
  id,
  'aria-label': ariaLabel,
  'aria-labelledby': ariaLabelledBy,
  className
}: DateRangePickerProps) {
  const controlled = value !== undefined
  const [uncontrolled, setUncontrolled] = React.useState<DateRange>(defaultValue)
  const range = controlled ? value : uncontrolled
  const [open, setOpen] = React.useState(false)
  const today = React.useMemo(() => todayISODate(timezone), [timezone])
  const [monthView, setMonthView] = React.useState(() => initialMonthFor([range.from, range.to, minDate], timezone))
  const secondMonth = addMonthsPlain(monthView, 1)

  const update = (next: DateRange) => {
    if (!controlled) setUncontrolled(next)
    onValueChange?.(next)
  }

  const summary = range.from && range.to ? `${range.from} – ${range.to}` : range.from ? `${range.from} – …` : null

  return (
    <div data-slot="date-range-picker" className={cn('inline-flex items-center gap-1', className)}>
      <Popover
        open={open}
        onOpenChange={next => {
          if (disabled && next) return
          if (next) setMonthView(initialMonthFor([range.from, range.to, minDate], timezone))
          setOpen(next)
        }}>
        <PopoverTrigger
          id={id}
          disabled={disabled}
          aria-label={ariaLabel}
          aria-labelledby={ariaLabelledBy}
          render={
            <Button type="button" variant="outline" size="default" className="justify-between gap-2 font-normal" />
          }>
          <RiCalendarLine aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
          <span className={cn('tabular-nums', !summary && 'text-fg-placeholder')}>{summary ?? placeholder}</span>
          {timezone && (
            <Badge variant="secondary" className="ml-1 px-1.5 py-0 text-[10px] font-normal">
              {timezone}
            </Badge>
          )}
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto max-w-[calc(100vw-2rem)] gap-3 p-3">
          <div className="flex flex-col gap-3 sm:flex-row">
            {presets && presets.length > 0 && (
              <div
                data-slot="date-range-presets"
                className="flex flex-wrap gap-1 border-b border-border pb-2 sm:w-36 sm:flex-col sm:border-r sm:border-b-0 sm:pr-3 sm:pb-0">
                {presets.map(preset => {
                  const constrained = constrainDateRange(preset.range, minDate, maxDate)
                  const active = constrained !== null && range.from === constrained.from && range.to === constrained.to
                  return (
                    <Button
                      key={preset.label}
                      type="button"
                      size="sm"
                      variant={active ? 'outline' : 'ghost'}
                      disabled={disabled || constrained === null}
                      aria-pressed={active}
                      className="justify-start text-xs"
                      onClick={() => {
                        if (!constrained) return
                        update(constrained)
                        setOpen(false)
                      }}>
                      {preset.label}
                    </Button>
                  )
                })}
              </div>
            )}
            <div className="grid gap-3">
              <div className="flex items-center justify-between gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-xs"
                  aria-label="Previous month"
                  onClick={() => setMonthView(prev => addMonthsPlain(prev, -1))}>
                  <RiArrowLeftSLine aria-hidden="true" className="size-4" />
                </Button>
                <span className="text-xs text-muted-foreground">{timezone ?? 'ISO 8601'}</span>
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-xs"
                  aria-label="Next month"
                  onClick={() => setMonthView(prev => addMonthsPlain(prev, 1))}>
                  <RiArrowRightSLine aria-hidden="true" className="size-4" />
                </Button>
              </div>
              <div className={cn('grid gap-4', numberOfMonths === 2 && 'sm:grid-cols-2')}>
                <CalendarMonth
                  year={monthView.year}
                  month={monthView.month}
                  locale={locale}
                  range={range}
                  today={today}
                  minDate={minDate}
                  maxDate={maxDate}
                  onSelect={iso => {
                    const next = applyDateRangeSelection(range, iso)
                    update(next)
                    if (next.from && next.to) setOpen(false)
                  }}
                />
                {numberOfMonths === 2 && (
                  <CalendarMonth
                    year={secondMonth.year}
                    month={secondMonth.month}
                    locale={locale}
                    range={range}
                    today={today}
                    minDate={minDate}
                    maxDate={maxDate}
                    onSelect={iso => {
                      const next = applyDateRangeSelection(range, iso)
                      update(next)
                      if (next.from && next.to) setOpen(false)
                    }}
                  />
                )}
              </div>
            </div>
          </div>
        </PopoverContent>
      </Popover>
      {clearable && (range.from || range.to) && !disabled && (
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          aria-label={clearLabel}
          onClick={() => update({ from: null, to: null })}>
          <RiCloseLine aria-hidden="true" className="size-3.5" />
        </Button>
      )}
    </div>
  )
}
