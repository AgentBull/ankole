'use client'

import { AddRegular, SubtractRegular } from '../icons'
import * as React from 'react'

import { composingKey } from '../lib/keyboard'
import { cn } from '../lib/utils'

export type NumberInputProps = Omit<
  React.ComponentProps<'input'>,
  'type' | 'value' | 'defaultValue' | 'onChange' | 'prefix'
> & {
  value?: number | null
  defaultValue?: number | null
  onValueChange?: (value: number | null) => void
  min?: number
  max?: number
  step?: number
  precision?: number
  allowNegative?: boolean
  prefix?: React.ReactNode
  suffix?: React.ReactNode
  showStepper?: boolean
  decrementLabel?: string
  incrementLabel?: string
  formatOptions?: Intl.NumberFormatOptions
  locale?: string
  variant?: 'default' | 'overlay'
}

function decimalPlaces(value: number): number {
  if (!Number.isFinite(value)) return 0
  const [mantissa = '', expPart] = String(Math.abs(value)).toLowerCase().split('e')
  const frac = (mantissa.split('.')[1] ?? '').length
  return expPart ? Math.max(0, frac - Number(expPart)) : frac
}

export function clampAndRoundNumber(
  value: number,
  options: { min?: number; max?: number; precision?: number } = {}
): number {
  let next = value
  if (options.min !== undefined && next < options.min) next = options.min
  if (options.max !== undefined && next > options.max) next = options.max
  if (options.precision !== undefined && Number.isInteger(options.precision) && options.precision >= 0 && next !== 0) {
    const sign = Math.sign(next)
    const abs = Math.abs(next)
    const shifted = Number(`${abs}e+${options.precision}`)
    if (Number.isFinite(shifted)) {
      next = sign * Number(`${Math.round(shifted)}e-${options.precision}`)
    } else {
      const factor = 10 ** options.precision
      next = (sign * Math.round((abs + Number.EPSILON) * factor)) / factor
    }
  }
  return Object.is(next, -0) ? 0 : next
}

export function parseEditableNumber(
  raw: string,
  options: { allowNegative?: boolean } = {}
): { state: 'empty' } | { state: 'intermediate' } | { state: 'invalid' } | { state: 'valid'; value: number } {
  const trimmed = raw.trim().replace(/,/g, '')
  if (trimmed === '') return { state: 'empty' }
  const allowNegative = options.allowNegative ?? true
  if (allowNegative && (trimmed === '-' || trimmed === '-.')) return { state: 'intermediate' }
  if (trimmed === '.') return { state: 'intermediate' }
  const pattern = allowNegative ? /^-?(?:\d+\.?\d*|\.\d+)$/ : /^(?:\d+\.?\d*|\.\d+)$/
  if (!pattern.test(trimmed)) return { state: 'invalid' }
  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed)) return { state: 'invalid' }
  return { state: 'valid', value: parsed }
}

export function formatEditableNumber(
  value: number | null | undefined,
  options: {
    precision?: number
    formatOptions?: Intl.NumberFormatOptions
    locale?: string
    focused?: boolean
  } = {}
): string {
  if (value === null || value === undefined || !Number.isFinite(value)) return ''
  if (options.focused) {
    const decimals = options.precision ?? decimalPlaces(value)
    if (decimals > 0 && decimals <= 20) {
      return value.toFixed(decimals).replace(/(\.\d*?[1-9])0+$|\.0+$/, '$1')
    }
    return options.precision === 0 ? value.toFixed(0) : String(value)
  }
  if (options.formatOptions) {
    return new Intl.NumberFormat(options.locale, {
      ...(options.precision !== undefined
        ? { minimumFractionDigits: options.precision, maximumFractionDigits: options.precision }
        : {}),
      ...options.formatOptions
    }).format(value)
  }
  return options.precision !== undefined ? value.toFixed(options.precision) : String(value)
}

export function stepEditableNumber(
  current: number | null | undefined,
  direction: 1 | -1,
  options: { step?: number; min?: number; max?: number; precision?: number } = {}
): number {
  const step = options.step && options.step > 0 ? options.step : 1
  const stepDecimals = decimalPlaces(step)
  const baseDecimals = current != null && Number.isFinite(current) ? decimalPlaces(current) : 0
  const precision = options.precision ?? Math.max(stepDecimals, baseDecimals)
  const base =
    current != null && Number.isFinite(current)
      ? current
      : options.min !== undefined && options.min > 0
        ? options.min - direction * step
        : 0
  return clampAndRoundNumber(base + direction * step, {
    min: options.min,
    max: options.max,
    precision
  })
}

function NumberInput({
  className,
  value,
  defaultValue = null,
  onValueChange,
  min,
  max,
  step = 1,
  precision,
  allowNegative,
  prefix,
  suffix,
  showStepper = false,
  decrementLabel = 'Decrease value',
  incrementLabel = 'Increase value',
  formatOptions,
  locale,
  variant = 'default',
  disabled = false,
  readOnly = false,
  onBlur,
  onFocus,
  onKeyDown,
  ...props
}: NumberInputProps) {
  const controlled = value !== undefined
  const [uncontrolledValue, setUncontrolledValue] = React.useState<number | null>(defaultValue)
  const currentValue = controlled ? (value ?? null) : uncontrolledValue
  const [focused, setFocused] = React.useState(false)
  const [draft, setDraft] = React.useState<string>(() =>
    formatEditableNumber(currentValue, { precision, formatOptions, locale, focused: false })
  )
  const canBeNegative = allowNegative ?? (min === undefined || min < 0)

  React.useEffect(() => {
    if (!focused) {
      setDraft(formatEditableNumber(currentValue, { precision, formatOptions, locale, focused: false }))
    }
  }, [currentValue, focused, precision, formatOptions, locale])

  const emitValue = (next: number | null) => {
    if (!controlled) setUncontrolledValue(next)
    onValueChange?.(next)
  }

  const commitDraft = (raw: string, keepFocused: boolean) => {
    const parsed = parseEditableNumber(raw, { allowNegative: canBeNegative })
    if (parsed.state === 'empty') {
      emitValue(null)
      setDraft('')
      return
    }
    if (parsed.state === 'valid') {
      const committed = clampAndRoundNumber(parsed.value, { min, max, precision })
      emitValue(committed)
      setDraft(formatEditableNumber(committed, { precision, formatOptions, locale, focused: keepFocused }))
      return
    }
    setDraft(formatEditableNumber(currentValue, { precision, formatOptions, locale, focused: keepFocused }))
  }

  const focusedParsed = focused ? parseEditableNumber(draft, { allowNegative: canBeNegative }) : null
  const effectiveValue =
    focused && focusedParsed ? (focusedParsed.state === 'valid' ? focusedParsed.value : null) : currentValue

  const applyStep = (direction: 1 | -1) => {
    if (disabled || readOnly) return
    const base = focusedParsed?.state === 'valid' ? focusedParsed.value : currentValue
    const next = stepEditableNumber(base, direction, { step, min, max, precision })
    emitValue(next)
    setDraft(formatEditableNumber(next, { precision, formatOptions, locale, focused }))
  }

  const atMin = min !== undefined && effectiveValue !== null && effectiveValue <= min
  const atMax = max !== undefined && effectiveValue !== null && effectiveValue >= max

  return (
    <div
      data-slot="number-input"
      data-variant={variant}
      data-disabled={disabled ? '' : undefined}
      className={cn(
        'inline-flex h-8 w-full min-w-0 items-center overflow-hidden text-sm transition-[background-color,border-color,box-shadow] duration-(--duration-feedback)',
        variant === 'overlay'
          ? 'h-9 rounded-[6px] border border-(--menu-field-edge) bg-(--menu-field) focus-within:border-[color-mix(in_srgb,var(--menu-icon-blue)_55%,transparent)] focus-within:shadow-[0_0_0_2px_color-mix(in_srgb,var(--menu-icon-blue)_12%,transparent)]'
          : 'rounded-control border border-field-edge border-b-input bg-field hover:bg-field-hover focus-within:border-control-edge focus-within:border-b-ring focus-within:bg-background focus-within:shadow-[inset_0_-1px_0_var(--color-ring)] data-disabled:border-b-transparent data-disabled:bg-field',
        className
      )}>
      {prefix != null && (
        <span
          data-slot="number-input-prefix"
          className="pointer-events-none shrink-0 pl-2.5 text-xs text-muted-foreground select-none">
          {prefix}
        </span>
      )}
      <input
        {...props}
        type="text"
        inputMode={precision === 0 && !canBeNegative ? 'numeric' : 'decimal'}
        disabled={disabled}
        readOnly={readOnly}
        value={
          focused ? draft : formatEditableNumber(currentValue, { precision, formatOptions, locale, focused: false })
        }
        onFocus={event => {
          setFocused(true)
          setDraft(formatEditableNumber(currentValue, { precision, formatOptions, locale, focused: true }))
          onFocus?.(event)
        }}
        onBlur={event => {
          setFocused(false)
          commitDraft(event.currentTarget.value, false)
          onBlur?.(event)
        }}
        onChange={event => {
          const raw = event.currentTarget.value
          const parsed = parseEditableNumber(raw, { allowNegative: canBeNegative })
          if (parsed.state === 'invalid') return
          setDraft(raw)
          if (parsed.state === 'empty') {
            emitValue(null)
          } else if (parsed.state === 'valid') {
            const withinBounds =
              (min === undefined || parsed.value >= min) && (max === undefined || parsed.value <= max)
            if (withinBounds) {
              emitValue(clampAndRoundNumber(parsed.value, { precision }))
            }
          }
        }}
        onKeyDown={event => {
          if (composingKey(event.nativeEvent)) {
            onKeyDown?.(event)
            return
          }
          if (event.key === 'ArrowUp') {
            event.preventDefault()
            applyStep(1)
          } else if (event.key === 'ArrowDown') {
            event.preventDefault()
            applyStep(-1)
          } else if (event.key === 'Enter') {
            commitDraft(event.currentTarget.value, true)
          }
          onKeyDown?.(event)
        }}
        className="h-full w-full min-w-0 flex-1 bg-transparent px-2.5 py-1.5 text-sm leading-5 tabular-nums outline-none placeholder:text-fg-placeholder disabled:cursor-not-allowed disabled:text-fg-disabled"
      />
      {suffix != null && (
        <span
          data-slot="number-input-suffix"
          className="pointer-events-none shrink-0 pr-2.5 text-xs text-muted-foreground select-none">
          {suffix}
        </span>
      )}
      {showStepper && (
        <div data-slot="number-input-stepper" className="flex h-full shrink-0 items-center border-l border-border/60">
          <button
            type="button"
            aria-label={decrementLabel}
            disabled={disabled || readOnly || atMin}
            onClick={() => applyStep(-1)}
            className="flex h-full w-7 cursor-pointer items-center justify-center text-muted-foreground transition-colors hover:bg-muted/70 hover:text-foreground focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring disabled:cursor-not-allowed disabled:opacity-40">
            <SubtractRegular aria-hidden="true" className="size-3.5" />
          </button>
          <button
            type="button"
            aria-label={incrementLabel}
            disabled={disabled || readOnly || atMax}
            onClick={() => applyStep(1)}
            className="flex h-full w-7 cursor-pointer items-center justify-center border-l border-border/60 text-muted-foreground transition-colors hover:bg-muted/70 hover:text-foreground focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-ring disabled:cursor-not-allowed disabled:opacity-40">
            <AddRegular aria-hidden="true" className="size-3.5" />
          </button>
        </div>
      )}
    </div>
  )
}

export { NumberInput }
