import { Input, Spinner, cn } from '@ankole/uikit'
import { RiEyeLine, RiEyeOffLine } from '@remixicon/react'
import { useEffect, useState, type ComponentProps } from 'react'
import { useTranslation } from 'react-i18next'

export const ENCRYPTED_VALUE_MASK = '__ENCRYPTED_VALUE_MASK__'

export function isEncryptedValueMask(value: string): boolean {
  return value === ENCRYPTED_VALUE_MASK
}

type EncryptedValueInputProps = Omit<ComponentProps<typeof Input>, 'type'> & {
  revealed?: boolean
  revealing?: boolean
  revealLabel: string
  onReveal?: () => void
}

/**
 * One secret input for both stored and replacement values.
 *
 * A stored secret starts with the fixed mask. Its eye button calls the
 * separately-authorized decryption endpoint; after the real value replaces the
 * mask, the same button only toggles local visibility.
 */
export function EncryptedValueInput({
  className,
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
  // Visibility derives from the props: a masked value is never shown, a
  // revealed value shows until the parent revokes it. `override` records the
  // operator's eye-button choice inside the current mask/reveal state and is
  // discarded whenever that state changes — so a revoked reveal always
  // re-masks instead of surviving through a stale local flag.
  const [override, setOverride] = useState<boolean>()
  const [previous, setPrevious] = useState({ masked, revealed })
  if (previous.masked !== masked || previous.revealed !== revealed) {
    setPrevious({ masked, revealed })
    setOverride(undefined)
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

  const revealStoredValue = masked && onReveal
  const label = revealStoredValue
    ? revealLabel
    : visible
      ? t('console.aria.hide_secret')
      : t('console.aria.reveal_secret')

  return (
    <div className="relative">
      <Input
        {...props}
        autoComplete="off"
        className={cn('pr-10', className)}
        spellCheck={false}
        type={visible ? 'text' : 'password'}
        value={value}
        onFocus={event => {
          if (masked) event.currentTarget.select()
          onFocus?.(event)
        }}
      />
      <button
        aria-label={label}
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
          <RiEyeOffLine className="size-4" />
        ) : (
          <RiEyeLine className="size-4" />
        )}
      </button>
    </div>
  )
}
