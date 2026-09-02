import * as React from 'react'
import { cn } from '../lib/utils'
import { Field, FieldLabel } from './field'
import { Input } from './input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './select'
import { ToggleGroup, ToggleGroupItem } from './toggle-group'

/**
 * Composed editor for 5-field cron expressions. The value is the cron string;
 * every edit emits a complete cron string. Presets cover the common shapes and
 * the custom mode keeps the raw expression editable, so no schedule becomes
 * unrepresentable.
 */

export type CronEditorMode = 'every_minutes' | 'hourly' | 'daily' | 'weekly' | 'monthly' | 'custom'

export type CronEditorFields = {
  /** Minute interval for `every_minutes`. */
  interval: number
  minute: number
  hour: number
  dayOfMonth: number
  /** 0 (Sunday) through 6 (Saturday). */
  weekday: number
}

export type CronEditorLabels = {
  mode: string
  modes: Record<CronEditorMode, string>
  interval: string
  minute: string
  time: string
  weekday: string
  /** Sunday first, matching cron weekday numbering. */
  weekdays: [string, string, string, string, string, string, string]
  dayOfMonth: string
  expression: string
}

const DEFAULT_LABELS: CronEditorLabels = {
  mode: 'Schedule',
  modes: {
    every_minutes: 'Every N minutes',
    hourly: 'Hourly',
    daily: 'Daily',
    weekly: 'Weekly',
    monthly: 'Monthly',
    custom: 'Custom expression'
  },
  interval: 'Minutes between runs',
  minute: 'Minute of the hour',
  time: 'Time',
  weekday: 'Day of the week',
  weekdays: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
  dayOfMonth: 'Day of the month',
  expression: 'Cron expression'
}

const DEFAULT_FIELDS: CronEditorFields = { interval: 5, minute: 0, hour: 9, dayOfMonth: 1, weekday: 1 }

const CRON_MODES: CronEditorMode[] = ['every_minutes', 'hourly', 'daily', 'weekly', 'monthly', 'custom']

/** Detects which preset a cron expression matches, or `custom`. */
export function cronEditorMode(expression: string): CronEditorMode {
  const parts = cronParts(expression)
  if (!parts) return 'custom'
  const [minute, hour, dayOfMonth, month, weekday] = parts

  if (month !== '*') return 'custom'
  if (/^\*\/\d+$/.test(minute) && hour === '*' && dayOfMonth === '*' && weekday === '*') return 'every_minutes'
  if (!isCronNumber(minute)) return 'custom'
  if (hour === '*' && dayOfMonth === '*' && weekday === '*') return 'hourly'
  if (!isCronNumber(hour)) return 'custom'
  if (dayOfMonth === '*' && weekday === '*') return 'daily'
  if (dayOfMonth === '*' && isCronNumber(weekday) && Number(weekday) <= 6) return 'weekly'
  if (isCronNumber(dayOfMonth) && weekday === '*') return 'monthly'
  return 'custom'
}

/** Reads the preset fields out of an expression, falling back to defaults per field. */
export function cronEditorFields(expression: string): CronEditorFields {
  const fields = { ...DEFAULT_FIELDS }
  const parts = cronParts(expression)
  if (!parts) return fields
  const [minute, hour, dayOfMonth, , weekday] = parts

  const intervalMatch = /^\*\/(\d+)$/.exec(minute)
  if (intervalMatch) fields.interval = clamp(Number(intervalMatch[1]), 1, 59)
  if (isCronNumber(minute)) fields.minute = clamp(Number(minute), 0, 59)
  if (isCronNumber(hour)) fields.hour = clamp(Number(hour), 0, 23)
  if (isCronNumber(dayOfMonth)) fields.dayOfMonth = clamp(Number(dayOfMonth), 1, 31)
  if (isCronNumber(weekday)) fields.weekday = clamp(Number(weekday), 0, 6)
  return fields
}

/** Builds the cron expression for one preset mode. `custom` returns the raw fallback. */
export function cronExpressionFor(mode: CronEditorMode, fields: CronEditorFields, rawFallback = ''): string {
  switch (mode) {
    case 'every_minutes':
      return `*/${clamp(fields.interval, 1, 59)} * * * *`
    case 'hourly':
      return `${clamp(fields.minute, 0, 59)} * * * *`
    case 'daily':
      return `${clamp(fields.minute, 0, 59)} ${clamp(fields.hour, 0, 23)} * * *`
    case 'weekly':
      return `${clamp(fields.minute, 0, 59)} ${clamp(fields.hour, 0, 23)} * * ${clamp(fields.weekday, 0, 6)}`
    case 'monthly':
      return `${clamp(fields.minute, 0, 59)} ${clamp(fields.hour, 0, 23)} ${clamp(fields.dayOfMonth, 1, 31)} * *`
    case 'custom':
      return rawFallback
  }
}

export type CronEditorModeOverride = { mode: CronEditorMode; forValue: string }

/**
 * The operator's explicit mode choice holds only for the expression it was
 * chosen for. Any other value means something outside the editor replaced the
 * expression, so the mode re-derives from the value.
 */
export function cronEditorModeWithOverride(
  override: CronEditorModeOverride | undefined,
  value: string
): CronEditorMode {
  return override && override.forValue === value ? override.mode : cronEditorMode(value)
}

function cronParts(expression: string): [string, string, string, string, string] | undefined {
  const parts = expression.trim().split(/\s+/)
  return parts.length === 5 ? (parts as [string, string, string, string, string]) : undefined
}

function isCronNumber(part: string): boolean {
  return /^\d+$/.test(part)
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, Math.trunc(value)))
}

function timeValue(fields: CronEditorFields): string {
  return `${String(fields.hour).padStart(2, '0')}:${String(fields.minute).padStart(2, '0')}`
}

export function CronEditor({
  className,
  disabled = false,
  labels = DEFAULT_LABELS,
  onChange,
  value
}: {
  className?: string
  disabled?: boolean
  labels?: CronEditorLabels
  onChange: (value: string) => void
  value: string
}) {
  // The expression is the single source of truth; only the operator's explicit
  // mode choice is local, because `custom` cannot be derived from a value that
  // also matches a preset. The override is pinned to the expression it was
  // chosen for: the editor's own emissions carry it forward, and an external
  // value replacement, such as a restore, drops it so the mode re-derives.
  const [override, setOverride] = React.useState<CronEditorModeOverride>()
  const mode = cronEditorModeWithOverride(override, value)
  const fields = cronEditorFields(value)

  const emitAs = (nextMode: CronEditorMode, next: string) => {
    setOverride({ mode: nextMode, forValue: next })
    onChange(next)
  }

  const emit = (nextMode: CronEditorMode, nextFields: CronEditorFields) => {
    emitAs(nextMode, cronExpressionFor(nextMode, nextFields, value))
  }

  const selectMode = (nextMode: CronEditorMode) => {
    if (nextMode === 'custom') setOverride({ mode: 'custom', forValue: value })
    else emit(nextMode, fields)
  }

  const setTime = (time: string) => {
    const [hourText = '', minuteText = ''] = time.split(':')
    if (!isCronNumber(hourText) || !isCronNumber(minuteText)) return
    emit(mode, { ...fields, hour: Number(hourText), minute: Number(minuteText) })
  }

  return (
    <div data-slot="cron-editor" className={cn('grid gap-4 border border-border bg-muted/20 p-4', className)}>
      <Field>
        <FieldLabel>{labels.mode}</FieldLabel>
        <Select
          value={mode}
          onValueChange={nextMode => {
            if (typeof nextMode === 'string' && CRON_MODES.includes(nextMode as CronEditorMode)) {
              selectMode(nextMode as CronEditorMode)
            }
          }}>
          <SelectTrigger aria-label={labels.mode} className="w-full" disabled={disabled}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {CRON_MODES.map(option => (
              <SelectItem key={option} value={option}>
                {labels.modes[option]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </Field>

      {mode === 'every_minutes' ? (
        <Field>
          <FieldLabel>{labels.interval}</FieldLabel>
          <Input
            aria-label={labels.interval}
            disabled={disabled}
            max={59}
            min={1}
            type="number"
            value={String(fields.interval)}
            onChange={event => emit(mode, { ...fields, interval: Number(event.target.value) })}
          />
        </Field>
      ) : null}

      {mode === 'hourly' ? (
        <Field>
          <FieldLabel>{labels.minute}</FieldLabel>
          <Input
            aria-label={labels.minute}
            disabled={disabled}
            max={59}
            min={0}
            type="number"
            value={String(fields.minute)}
            onChange={event => emit(mode, { ...fields, minute: Number(event.target.value) })}
          />
        </Field>
      ) : null}

      {mode === 'weekly' ? (
        <Field>
          <FieldLabel>{labels.weekday}</FieldLabel>
          <ToggleGroup
            aria-label={labels.weekday}
            className="flex-wrap"
            disabled={disabled}
            value={[String(fields.weekday)]}
            onValueChange={groupValue => {
              const next = groupValue.find(item => item !== String(fields.weekday)) ?? groupValue[0]
              if (typeof next === 'string' && isCronNumber(next)) emit(mode, { ...fields, weekday: Number(next) })
            }}>
            {labels.weekdays.map((weekdayLabel, index) => (
              <ToggleGroupItem key={weekdayLabel} aria-label={weekdayLabel} size="sm" value={String(index)}>
                {weekdayLabel}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </Field>
      ) : null}

      {mode === 'monthly' ? (
        <Field>
          <FieldLabel>{labels.dayOfMonth}</FieldLabel>
          <Input
            aria-label={labels.dayOfMonth}
            disabled={disabled}
            max={31}
            min={1}
            type="number"
            value={String(fields.dayOfMonth)}
            onChange={event => emit(mode, { ...fields, dayOfMonth: Number(event.target.value) })}
          />
        </Field>
      ) : null}

      {mode === 'daily' || mode === 'weekly' || mode === 'monthly' ? (
        <Field>
          <FieldLabel>{labels.time}</FieldLabel>
          <Input
            aria-label={labels.time}
            disabled={disabled}
            type="time"
            value={timeValue(fields)}
            onChange={event => setTime(event.target.value)}
          />
        </Field>
      ) : null}

      <Field>
        <FieldLabel>{labels.expression}</FieldLabel>
        {mode === 'custom' ? (
          <Input
            aria-label={labels.expression}
            className="font-mono text-xs"
            disabled={disabled}
            spellCheck={false}
            value={value}
            onChange={event => emitAs('custom', event.target.value)}
          />
        ) : (
          <code className="flex min-h-8 items-center border border-border bg-background px-3 font-mono text-xs text-muted-foreground">
            {value}
          </code>
        )}
      </Field>
    </div>
  )
}
