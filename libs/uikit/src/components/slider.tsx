'use client'

import {
  Slider as SliderPrimitive,
  SliderControl,
  SliderIndicator,
  SliderThumb,
  SliderTrack,
  SliderValue as SliderValuePrimitive
} from '@ui-sdk/react/slider'
import * as React from 'react'

import { cn } from '../lib/utils'

export type SliderValue = number | number[]

export type SliderProps<Value extends SliderValue = SliderValue> = Omit<
  React.ComponentProps<typeof SliderPrimitive<Value>>,
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
  // shortcut: ui-sdk formats every thumb's spoken value alike, so screen readers hear the first thumb's format on
  // each thumb; give each thumb its own format if a range ever formats its ends differently.
  format = formatValue && (rawValue => formatValue(rawValue, 0)),
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

  return (
    <SliderPrimitive
      value={value}
      defaultValue={defaultValue}
      min={min}
      max={max}
      step={step}
      disabled={disabled}
      format={format}
      aria-labelledby={resolvedLabelledBy}
      className={cn('grid w-full gap-1.5 select-none data-disabled:opacity-50', className)}
      {...props}>
      {(label != null || showValue) && (
        <div className="flex items-center justify-between gap-2 text-sm">
          {label != null ? (
            <span id={labelId} data-slot="slider-label" className="font-medium text-fg-primary">
              {label}
            </span>
          ) : (
            <span />
          )}
          {showValue && (
            <SliderValuePrimitive className="font-mono text-xs text-fg-secondary tabular-nums">
              {state => formatSliderDisplay(normalizeThumbs(state.value), formatValue)}
            </SliderValuePrimitive>
          )}
        </div>
      )}
      <SliderControl className="relative flex min-h-6 w-full touch-pan-y items-center py-1 data-[orientation=vertical]:touch-pan-x data-disabled:cursor-not-allowed">
        {/* ui-sdk places the indicator and the thumbs inside the track, so the track lets the thumbs overhang it. */}
        <SliderTrack className="relative h-1.5 w-full grow rounded-full bg-layer-03">
          <SliderIndicator className="h-full rounded-full bg-primary motion-safe:transition-[width,left] motion-safe:duration-75" />
          {thumbs.map((_, index) => (
            <SliderThumb
              key={index}
              index={index}
              aria-label={getAriaLabel?.(index)}
              className="block size-4 shrink-0 cursor-grab rounded-full border-2 border-primary bg-page shadow-xs transition-[box-shadow] after:absolute after:-inset-1 pointer-coarse:after:-inset-3.5 focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-ring active:cursor-grabbing motion-safe:transition-[scale,box-shadow] motion-safe:active:scale-105 data-disabled:pointer-events-none"
            />
          ))}
        </SliderTrack>
      </SliderControl>
    </SliderPrimitive>
  )
}

export { Slider }
