import { Progress as ProgressPrimitive } from '@base-ui/react/progress'
import type { CSSProperties } from 'react'

import { cn } from '../lib/utils'

function progressFraction(value: number | null | undefined, min: number, max: number) {
  if (value == null || !Number.isFinite(value) || max === min) return 0
  return Math.min(1, Math.max(0, (value - min) / (max - min)))
}

function Progress({ className, children, max = 100, min = 0, style, value, ...props }: ProgressPrimitive.Root.Props) {
  return (
    <ProgressPrimitive.Root
      value={value}
      max={max}
      min={min}
      data-slot="progress"
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
    </ProgressPrimitive.Root>
  )
}

function ProgressTrack({ className, ...props }: ProgressPrimitive.Track.Props) {
  return (
    <ProgressPrimitive.Track
      className={cn(
        'relative flex h-2 w-full min-w-12 items-center overflow-x-hidden rounded-none bg-muted',
        className
      )}
      data-slot="progress-track"
      {...props}
    />
  )
}

function ProgressIndicator({ className, style, ...props }: ProgressPrimitive.Indicator.Props) {
  return (
    <ProgressPrimitive.Indicator
      data-slot="progress-indicator"
      className={cn(
        'h-full w-full origin-left bg-primary transition-transform duration-(--duration-dialog) ease-out',
        className
      )}
      style={{ width: '100%', transform: 'scaleX(var(--progress-fraction))', ...style }}
      {...props}
    />
  )
}

function ProgressLabel({ className, ...props }: ProgressPrimitive.Label.Props) {
  return (
    <ProgressPrimitive.Label
      className={cn('text-sm leading-5 font-normal tracking-normal', className)}
      data-slot="progress-label"
      {...props}
    />
  )
}

function ProgressValue({ className, ...props }: ProgressPrimitive.Value.Props) {
  return (
    <ProgressPrimitive.Value
      className={cn('ml-auto text-sm leading-5 text-muted-foreground tabular-nums', className)}
      data-slot="progress-value"
      {...props}
    />
  )
}

export { Progress, ProgressIndicator, ProgressLabel, ProgressTrack, ProgressValue }
