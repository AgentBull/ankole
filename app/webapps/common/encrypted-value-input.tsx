import { Input, Spinner, cn } from '@ankole/uikit'
import { EyeOffRegular, EyeRegular } from '@ankole/uikit/icons'
import { useEffect, useState, type ComponentProps } from 'react'
import { useTranslation } from 'react-i18next'

export const ENCRYPTED_VALUE_MASK = '__ENCRYPTED_VALUE_MASK__'

export function isEncryptedValueMask(value: string): boolean {
  return value === ENCRYPTED_VALUE_MASK
}

export type EncryptedValueInputProps = Omit<ComponentProps<typeof Input>, 'type'> & {
  hideLabel?: string
  revealed?: boolean
  revealing?: boolean
  revealLabel: string
  onReveal?: () => void
}

/**
 * One secret input for both stored and replacement values.
 *
 * A stored secret starts with the fixed mask. Its eye button calls the
 * separately-authorized decryption endpoint when `onReveal` is provided; when
 * the caller lacks decrypt permission (`masked && !onReveal`), the eye button
 * stays hidden until a replacement value is typed.
 */
export function EncryptedValueInput({
  className,
  hideLabel,
  onFocus,
  onReveal,
  revealLabel,
  revealed = false,
  revealing = false,
  value,
  ...props
}: EncryptedValueInputProps) {
  const { t } = useTranslation()
  const masked = typeof value === 'string' && isEncryptedValueMask(value)
  const hasValue = typeof value === 'string' && value.length > 0
  // Visibility derives from the props: a masked value is never shown, a
  // revealed value shows until the parent revokes it. `override` records the
  // operator's eye-button choice inside the current mask/reveal state and is
  // discarded whenever that state changes or a non-empty draft is cleared — so
  // a revoked reveal or saved draft always re-masks instead of surviving
  // through a stale local flag.
  const [override, setOverride] = useState<boolean>()
  const [previous, setPrevious] = useState({ masked, revealed, hasValue })
  if (previous.masked !== masked || previous.revealed !== revealed || (previous.hasValue && !hasValue)) {
    setPrevious({ masked, revealed, hasValue })
    setOverride(undefined)
  } else if (previous.hasValue !== hasValue) {
    setPrevious({ masked, revealed, hasValue })
  }
  const visible = !masked && (override ?? revealed)

  useEffect(() => {
    if (!visible) return
    const remask = () => setOverride(false)
    const timeout = window.setTimeout(remask, 30_000)
    window.addEventListener('blur', remask)
    return () => {
      window.clearTimeout(timeout)
      window.removeEventListener('blur', remask)
    }
  }, [visible])

  const showToggle = !masked || Boolean(onReveal)
  const revealStoredValue = masked && onReveal
  const label = revealStoredValue
    ? revealLabel
    : visible
      ? (hideLabel ?? t('common.hide_secret'))
      : hideLabel
        ? revealLabel
        : t('common.reveal_secret')

  return (
    <div className="relative">
      <Input
        {...props}
        autoCapitalize="off"
        autoComplete="off"
        autoCorrect="off"
        className={cn(showToggle ? 'pr-10' : undefined, className)}
        spellCheck={false}
        type={visible ? 'text' : 'password'}
        value={value}
        onFocus={event => {
          if (masked) event.currentTarget.select()
          onFocus?.(event)
        }}
      />
      {showToggle ? (
        <button
          aria-label={label}
          aria-pressed={revealStoredValue ? undefined : visible}
          className="absolute inset-y-0 right-0 grid w-10 place-items-center text-muted-foreground hover:text-foreground disabled:cursor-wait disabled:opacity-60"
          disabled={revealing}
          title={label}
          type="button"
          onClick={() => {
            if (revealStoredValue) onReveal()
            else setOverride(!visible)
          }}>
          {revealing ? (
            <Spinner className="size-4" />
          ) : visible ? (
            <EyeOffRegular aria-hidden className="size-4" />
          ) : (
            <EyeRegular aria-hidden className="size-4" />
          )}
        </button>
      ) : null}
    </div>
  )
}
