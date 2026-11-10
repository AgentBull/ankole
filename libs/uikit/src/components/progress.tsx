import { Progress as ProgressPrimitive } from '@base-ui/react/progress'
import type { ComponentPropsWithoutRef, CSSProperties } from 'react'

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
      className={cn('relative flex h-1 w-full min-w-12 items-center overflow-hidden rounded-full bg-muted', className)}
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
        'h-full w-full rounded-full bg-foreground transition-transform duration-(--duration-dialog) ease-out',
        className
      )}
      style={{ width: '100%', transform: 'translateX(calc((var(--progress-fraction) - 1) * 100%))', ...style }}
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
