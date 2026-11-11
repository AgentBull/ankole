import { InputOTP, InputOTPGroup, InputOTPSlot } from '@ankole/uikit'

/**
 * The six-digit email code field. `invalid` marks a code the server rejected, and `status` shows a check that is
 * running or a code that was accepted, so the field itself answers each attempt.
 */
export function EmailOtpInput({
  id,
  name,
  value,
  disabled,
  invalid = false,
  status,
  onChange
}: {
  id: string
  name?: string
  value: string
  disabled?: boolean
  invalid?: boolean
  status?: 'verifying' | 'success'
  onChange: (value: string) => void
}) {
  return (
    <InputOTP
      id={id}
      name={name}
      inputMode="numeric"
      pattern="^[0-9]+$"
      maxLength={6}
      autoComplete="one-time-code"
      required
      autoFocus
      disabled={disabled}
      aria-invalid={invalid || undefined}
      data-status={status}
      value={value}
      containerClassName="min-w-0 w-full max-w-80"
      pasteTransformer={pasted => pasted.replace(/\D/g, '')}
      onChange={onChange}>
      <InputOTPGroup className="grid w-full grid-cols-6 gap-2">
        {Array.from({ length: 6 }, (_, index) => (
          <InputOTPSlot key={index} index={index} className="h-11 w-full text-base" />
        ))}
      </InputOTPGroup>
    </InputOTP>
  )
}
