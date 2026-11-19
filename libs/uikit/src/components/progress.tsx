import {
  Progress as ProgressPrimitive,
  ProgressIndicator as ProgressIndicatorPrimitive,
  ProgressLabel as ProgressLabelPrimitive,
  ProgressTrack as ProgressTrackPrimitive,
  ProgressValue as ProgressValuePrimitive
} from '@ui-sdk/react/progress'
import type { ComponentProps, ComponentPropsWithoutRef, CSSProperties, ReactNode } from 'react'

import { cn } from '../lib/utils'

function progressFraction(value: number | null | undefined, min: number, max: number) {
  if (value == null || !Number.isFinite(value) || max === min) return 0
  return Math.min(1, Math.max(0, (value - min) / (max - min)))
}

function Progress({
  className,
  children,
  max = 100,
  min = 0,
  style,
  value,
  ...props
}: Omit<ComponentProps<typeof ProgressPrimitive>, 'children'> & { children?: ReactNode }) {
  return (
    <ProgressPrimitive
      value={value}
      max={max}
      min={min}
      style={
        {
          ...style,
          '--progress-fraction': String(progressFraction(value, min, max))
        } as CSSProperties
      }
      className={cn('flex flex-wrap gap-2', className)}
      {...props}>
      {children}
      <ProgressTrack>
        <ProgressIndicator />
      </ProgressTrack>
    </ProgressPrimitive>
  )
}

const slidingBar: CSSProperties = {
  width: '100%',
  transform: 'translateX(calc((var(--progress-fraction) - 1) * 100%))'
}

function ProgressTrack({ className, ...props }: ComponentProps<typeof ProgressTrackPrimitive>) {
  return (
    <ProgressTrackPrimitive
      className={cn(
        'relative flex h-1 w-full min-w-12 items-center overflow-hidden rounded-full bg-layer-03',
        className
      )}
      {...props}
    />
  )
}

/**
 * The filled bar. It slides a full-width bar along the track instead of taking the width that ui-sdk writes inline,
 * so the browser animates a transform rather than a layout change.
 */
function ProgressIndicator({ className, ...props }: ComponentProps<typeof ProgressIndicatorPrimitive>) {
  return (
    <ProgressIndicatorPrimitive
      className={cn(
        'h-full w-full rounded-full bg-fg-primary motion-safe:transition-transform motion-safe:duration-(--duration-dialog) motion-safe:ease-out',
        className
      )}
      render={indicator => <div {...indicator} style={{ ...indicator.style, ...slidingBar }} />}
      {...props}
    />
  )
}

function ProgressLabel({ className, ...props }: ComponentProps<typeof ProgressLabelPrimitive>) {
  return (
    <ProgressLabelPrimitive className={cn('text-sm leading-5 font-normal tracking-normal', className)} {...props} />
  )
}

function ProgressValue({ className, ...props }: ComponentProps<typeof ProgressValuePrimitive>) {
  return (
    <ProgressValuePrimitive
      className={cn('ml-auto text-sm leading-5 text-fg-secondary tabular-nums', className)}
      {...props}
    />
  )
}

/**
 * Determinate progress drawn in the Spinner's geometry, for progress that has to fit an icon slot.
 * `value` runs from 0 to 100.
 */
function ProgressRing({
  value,
  className,
  ...props
}: { value: number } & Omit<ComponentPropsWithoutRef<'svg'>, 'children'>) {
  const percent = Math.round(progressFraction(value, 0, 100) * 100)
  return (
    <svg
      data-slot="progress-ring"
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={percent}
      viewBox="0 0 16 16"
      fill="none"
      strokeWidth="1.75"
      className={cn('inline-block size-4 -rotate-90 stroke-current', className)}
      {...props}>
      <circle cx="8" cy="8" r="6.5" opacity="0.24" />
      <circle cx="8" cy="8" r="6.5" pathLength="100" strokeLinecap="round" strokeDasharray={`${percent} 100`} />
    </svg>
  )
}

export { Progress, ProgressIndicator, ProgressLabel, ProgressRing, ProgressTrack, ProgressValue }
