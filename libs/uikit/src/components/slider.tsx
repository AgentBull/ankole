'use client'

import { Slider as SliderPrimitive } from '@base-ui/react/slider'
import * as React from 'react'

import { cn } from '../lib/utils'

export type SliderValue = number | readonly number[]

export type SliderProps<Value extends SliderValue = SliderValue> = Omit<
  SliderPrimitive.Root.Props<Value>,
  'children'
> & {
  label?: React.ReactNode
  formatValue?: (value: number, index: number) => string
  showValue?: boolean
  thumbLabels?: readonly string[]
}

export function formatSliderDisplay(
  values: readonly number[],
  formatValue?: (value: number, index: number) => string
): string {
  const format = formatValue ?? ((value: number) => String(value))
  return values.map((value, index) => format(value, index)).join(' – ')
}

function normalizeThumbs(value?: SliderValue, defaultValue?: SliderValue, min = 0): readonly number[] {
  const active = value ?? defaultValue ?? min
  return Array.isArray(active) ? active : [active as number]
}

function Slider<Value extends SliderValue = number>({
  className,
  value,
  defaultValue,
  min = 0,
  max = 100,
  step = 1,
  disabled = false,
  label,
  formatValue,
  showValue = false,
  thumbLabels,
  'aria-label': ariaLabel,
  'aria-labelledby': ariaLabelledBy,
  ...props
}: SliderProps<Value>) {
  const labelId = React.useId()
  const thumbs = normalizeThumbs(value, defaultValue, min)
  const resolvedLabelledBy = ariaLabelledBy ?? (label != null ? labelId : undefined)
  const getAriaLabel =
    thumbLabels?.length || (ariaLabel && thumbs.length > 1)
      ? (index: number) =>
          thumbLabels?.[index] ?? (ariaLabel ? `${ariaLabel} (${index === 0 ? 'min' : 'max'})` : `Thumb ${index + 1}`)
      : ariaLabel
        ? () => ariaLabel
        : undefined
  const getAriaValueText = formatValue
    ? (_formatted: string, rawValue: number, index: number) => formatValue(rawValue, index)
    : undefined

  return (
    <SliderPrimitive.Root
      data-slot="slider"
      value={value}
      defaultValue={defaultValue}
      min={min}
      max={max}
      step={step}
      disabled={disabled}
      aria-labelledby={resolvedLabelledBy}
      className={cn('grid w-full gap-1.5 select-none data-disabled:opacity-50', className)}
      {...props}>
      {(label != null || showValue) && (
        <div className="flex items-center justify-between gap-2 text-sm">
          {label != null ? (
            <span id={labelId} data-slot="slider-label" className="font-medium text-foreground">
              {label}
            </span>
          ) : (
            <span />
          )}
          {showValue && (
            <SliderPrimitive.Value
              data-slot="slider-value"
              className="font-mono text-xs text-muted-foreground tabular-nums">
              {(_formatted, values) => formatSliderDisplay(values, formatValue)}
            </SliderPrimitive.Value>
          )}
        </div>
      )}
      <SliderPrimitive.Control
        data-slot="slider-control"
        className="relative flex min-h-6 w-full touch-none items-center py-1 data-disabled:cursor-not-allowed">
        <SliderPrimitive.Track
          data-slot="slider-track"
          className="relative h-1.5 w-full grow overflow-hidden rounded-full bg-muted">
          <SliderPrimitive.Indicator
            data-slot="slider-indicator"
            className="h-full rounded-full bg-primary transition-[width,left] duration-75"
          />
        </SliderPrimitive.Track>
        {thumbs.map((_, index) => (
          <SliderPrimitive.Thumb
            key={index}
            index={index}
            data-slot="slider-thumb"
            getAriaLabel={getAriaLabel}
            getAriaValueText={getAriaValueText}
            className="block size-4 shrink-0 cursor-grab rounded-full border-2 border-primary bg-background shadow-xs transition-[transform,box-shadow] focus-within:ring-3 focus-within:ring-ring/50 focus-within:outline-none active:scale-105 active:cursor-grabbing data-disabled:pointer-events-none"
          />
        ))}
      </SliderPrimitive.Control>
    </SliderPrimitive.Root>
  )
}

export { Slider }
