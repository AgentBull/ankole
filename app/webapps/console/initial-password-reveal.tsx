import { Button, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine } from '@remixicon/react'
import { useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

/**
 * One-time initial password readout with a copy action. The password lives
 * only in mutation data, so leaving the surface discards it for good — the
 * warning text says exactly that.
 */
export function InitialPasswordReveal({ actions, password }: { actions?: ReactNode; password: string }) {
  const { t } = useTranslation()
  const [copied, setCopied] = useState(false)

  async function copyPassword() {
    try {
      await navigator.clipboard.writeText(password)
      setCopied(true)
      toast.success(t('console.principals.password_copied'))
      window.setTimeout(() => setCopied(false), 2000)
    } catch {
      toast.error(t('console.principals.copy_failed'))
    }
  }

  return (
    <div className="grid gap-4">
      <div className="flex min-w-0 flex-col gap-3 border border-border/70 bg-muted/30 p-4 sm:flex-row sm:items-center">
        <code className="min-w-0 flex-1 break-all font-mono text-lg leading-7 select-all">{password}</code>
        <Button onClick={copyPassword} size="sm" type="button" variant="outline">
          {copied ? t('console.principals.password_copied') : t('console.principals.copy_password')}
          {copied ? (
            <RiCheckLine aria-hidden data-icon="inline-end" />
          ) : (
            <RiFileCopyLine aria-hidden data-icon="inline-end" />
          )}
        </Button>
      </div>
      <p className="text-sm leading-6 text-muted-foreground">{t('console.principals.initial_password_description')}</p>
      {actions ? <div className="flex flex-wrap items-center gap-3">{actions}</div> : null}
    </div>
  )
}
