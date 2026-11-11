'use client'

import { RiSubtractLine } from '@remixicon/react'
import { OTPInput, OTPInputContext } from 'input-otp'
import * as React from 'react'
import { cn } from '../lib/utils'

function InputOTP({
  className,
  containerClassName,
  ...props
}: React.ComponentProps<typeof OTPInput> & {
  containerClassName?: string
}) {
  return (
    <OTPInput
      data-slot="input-otp"
      containerClassName={cn('cn-input-otp group/input-otp flex items-center', containerClassName)}
      inputMode="numeric"
      autoComplete="one-time-code"
      spellCheck={false}
      className={cn('disabled:cursor-not-allowed', className)}
      {...props}
    />
  )
}

function InputOTPGroup({ className, children, ...props }: React.ComponentProps<'div'>) {
  const slots = React.useContext(OTPInputContext)?.slots
  const previousSlots = React.useRef(slots)
  const ringRef = React.useRef<HTMLSpanElement>(null)

  React.useLayoutEffect(() => {
    const ring = ringRef.current
    const group = ring?.parentElement
    if (!ring || !group) return

    // A paste or autofill can replace several digits in one update. Let those digits arrive in order.
    const changed =
      slots?.flatMap((slot, index) =>
        slot.char && slot.char !== previousSlots.current?.[index]?.char ? [index] : []
      ) ?? []
    previousSlots.current = slots
    const [first] = changed
    if (first !== undefined && changed.length > 1) {
      for (const index of changed) {
        const digit = group.querySelector<HTMLElement>(`[data-otp-digit="${index}"]`)
        if (digit) digit.style.animationDelay = `${(index - first) * 45}ms`
      }
    }

    const activeSlots = group.querySelectorAll<HTMLElement>(':scope > [data-slot="input-otp-slot"][data-active="true"]')
    const active = activeSlots.length === 1 ? activeSlots[0] : undefined
    ring.toggleAttribute('data-visible', Boolean(active))
    if (!active) return

    const place = () => {
      ring.style.transform = `translate(${active.offsetLeft}px, ${active.offsetTop}px)`
      ring.style.width = `${active.offsetWidth}px`
      ring.style.height = `${active.offsetHeight}px`
    }
    place()

    const observer = new ResizeObserver(place)
    observer.observe(group)
    observer.observe(active)
    return () => observer.disconnect()
  }, [slots])

  return (
    <div
      data-slot="input-otp-group"
      className={cn('group/otp-slots relative flex items-center gap-1', className)}
      {...props}>
      {children}
      <span
        ref={ringRef}
        data-slot="input-otp-focus"
        aria-hidden
        className="pointer-events-none absolute top-0 left-0 z-10 grid place-items-center rounded-control border border-transparent opacity-0 shadow-[inset_0_-1px_0_var(--color-ring)] data-visible:opacity-100 group-has-[>[data-active=true][aria-invalid=true]]/otp-slots:shadow-[inset_0_-1px_0_var(--color-destructive)] group-has-[input:disabled]/input-otp:hidden motion-safe:[transition:transform_260ms_cubic-bezier(.22,1,.36,1),width_260ms_cubic-bezier(.22,1,.36,1),opacity_180ms_ease]">
        {slots?.some(slot => slot.hasFakeCaret) && (
          <span className="h-4 w-px bg-foreground motion-safe:animate-otp-caret" />
        )}
      </span>
    </div>
  )
}

function InputOTPSlot({
  index,
  className,
  ...props
}: React.ComponentProps<'div'> & {
  index: number
}) {
  const inputOTPContext = React.useContext(OTPInputContext)
  const { char, hasFakeCaret, isActive } = inputOTPContext?.slots[index] ?? {}

  return (
    <div
      data-slot="input-otp-slot"
      data-active={isActive}
      className={cn(
        'relative flex size-8 items-center justify-center rounded-control border border-field-edge border-b-input bg-field text-sm transition-[color,border-color,background-color] outline-none aria-invalid:border-b-destructive aria-invalid:shadow-[inset_0_-1px_0_var(--color-destructive)] data-[active=true]:z-10 data-[active=true]:border-control-edge data-[active=true]:border-b-ring data-[active=true]:bg-background data-[active=true]:shadow-[inset_0_-1px_0_var(--color-ring)] group-has-[input:disabled]/input-otp:border-b-transparent group-has-[input:disabled]/input-otp:text-fg-disabled',
        'group-has-[>[data-slot=input-otp-focus][data-visible]]/otp-slots:data-[active=true]:border-b-input group-has-[>[data-slot=input-otp-focus][data-visible]]/otp-slots:data-[active=true]:shadow-none',
        className
      )}
      {...props}>
      {char && (
        <span key={char} data-otp-digit={index} className="block motion-safe:animate-otp-digit">
          {char}
        </span>
      )}
      {hasFakeCaret && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center group-has-[>[data-slot=input-otp-focus][data-visible]]/otp-slots:hidden">
          <div className="h-4 w-px bg-foreground motion-safe:animate-otp-caret" />
        </div>
      )}
    </div>
  )
}

function InputOTPSeparator({ ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="input-otp-separator"
      className="flex items-center [&_svg:not([class*='size-'])]:size-3.5"
      {...props}>
      <RiSubtractLine />
    </div>
  )
}

export { InputOTP, InputOTPGroup, InputOTPSeparator, InputOTPSlot }
