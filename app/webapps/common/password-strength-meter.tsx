import { cn } from '@ankole/uikit'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { loadPasswordScorer, strengthLevel, type PasswordStrengthLevel } from './password-strength'

const segmentCount: Record<PasswordStrengthLevel, number> = {
  weak: 1,
  fair: 2,
  good: 3,
  strong: 4
}

const segmentTone: Record<PasswordStrengthLevel, string> = {
  weak: 'bg-destructive',
  fair: 'bg-warning',
  good: 'bg-success/70',
  strong: 'bg-success'
}

/**
 * Advisory password-strength readout: four segments plus a level label. It
 * scores after a short debounce with the lazily loaded zxcvbn chunk and never
 * blocks input; until the chunk answers it shows neutral segments.
 */
export function PasswordStrengthMeter({ className, password }: { className?: string; password: string }) {
  const { t } = useTranslation()
  const [score, setScore] = useState<number>()

  useEffect(() => {
    if (!password) {
      setScore(undefined)
      return
    }

    let cancelled = false
    const timer = window.setTimeout(() => {
      void loadPasswordScorer().then(scorer => {
        if (!cancelled) setScore(scorer(password))
      })
    }, 150)

    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [password])

  if (!password) return null

  const level = score === undefined ? undefined : strengthLevel(score)

  return (
    <div className={cn('grid gap-1.5', className)}>
      <div className="flex items-center gap-3">
        <div className="flex flex-1 gap-1" role="presentation">
          {Array.from({ length: 4 }, (_, index) => (
            <span
              key={index}
              className={cn(
                'h-1 flex-1',
                level && index < segmentCount[level] ? segmentTone[level] : 'bg-muted-foreground/25'
              )}
            />
          ))}
        </div>
        <span aria-live="polite" className="text-xs leading-4 text-muted-foreground">
          {level ? `${t('common.password_strength_label')}: ${t(`common.password_strength_${level}`)}` : null}
        </span>
      </div>
      <p className="text-xs leading-4 text-muted-foreground">{t('common.password_strength_hint')}</p>
    </div>
  )
}
