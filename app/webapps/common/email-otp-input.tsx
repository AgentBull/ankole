import { InputOTP, InputOTPGroup, InputOTPSlot } from '@ankole/uikit'

export function EmailOtpInput({
  id,
  name,
  value,
  disabled,
  onChange
}: {
  id: string
  name?: string
  value: string
  disabled?: boolean
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
