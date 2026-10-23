import {
  Button,
  buttonVariants,
  cn,
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@ankole/uikit'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ankoleWebPrincipalControllerCreateLocalPasswordResetMutation } from '../api/generated/@tanstack/react-query.gen'
import type { PrincipalRecord } from './principals'
import { ErrorBlock } from '../../common/error-block'
import { StatusIndicator } from '../console-form'
import { InitialPasswordReveal } from '../initial-password-reveal'
import { MustChangePasswordField } from './principal-create'

/**
 * Local-password area of the principal detail page: credential status plus a
 * reset flow. One dialog carries the whole flow — confirm with the
 * must-change choice, then the one-time password. Closing it discards the
 * password for good.
 */
export function LocalPasswordSection({ principal }: { principal: PrincipalRecord }) {
  const { t } = useTranslation()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [mustChange, setMustChange] = useState(true)
  const reset = useMutation({
    ...ankoleWebPrincipalControllerCreateLocalPasswordResetMutation()
    // The status badge reflects the new credential as soon as the dialog shows it.
  })
  const credential = principal.local_credential_status
  const actionLabel = credential ? t('console.principals.reset_password') : t('console.principals.generate_password')

  const openDialog = () => {
    reset.reset()
    setMustChange(true)
    setDialogOpen(true)
  }

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.principals.local_password_title')}</h3>
        <p className="max-w-2xl text-sm leading-6 text-muted-foreground">
          {t('console.principals.local_password_description')}
        </p>
      </div>
      <div className="flex flex-wrap items-center gap-3">
        <StatusIndicator tone={credential ? (credential === 'must_change' ? 'warning' : 'positive') : 'neutral'}>
          {credential
            ? credential === 'must_change'
              ? t('console.principals.password_status_must_change')
              : t('console.principals.password_status_active')
            : t('console.principals.password_status_absent')}
        </StatusIndicator>
        <Button size="sm" type="button" variant="outline" onClick={openDialog}>
          {actionLabel}
        </Button>
      </div>
      <Dialog
        open={dialogOpen}
        onOpenChange={open => {
          // A close during the reset request would discard a password the
          // server is already writing; the dialog stays open until the
          // result shows.
          if (!open && reset.isPending) return
          setDialogOpen(open)
          if (!open) reset.reset()
        }}>
        <DialogContent closeLabel={t('common.close')}>
          {reset.data ? (
            <>
              <DialogHeader>
                <DialogTitle>
                  {t(
                    mustChange
                      ? 'console.principals.initial_password_title'
                      : 'console.principals.initial_password_title_static'
                  )}
                </DialogTitle>
              </DialogHeader>
              <InitialPasswordReveal password={reset.data.initial_password} />
              <DialogFooter>
                <DialogClose className={cn(buttonVariants({ size: 'sm' }))}>{t('common.close')}</DialogClose>
              </DialogFooter>
            </>
          ) : (
            <>
              <DialogHeader>
                <DialogTitle>{t('console.principals.reset_confirm_title')}</DialogTitle>
                <DialogDescription>{t('console.principals.reset_confirm_description')}</DialogDescription>
              </DialogHeader>
              <ErrorBlock error={reset.error} />
              <MustChangePasswordField checked={mustChange} onChange={setMustChange} />
              <DialogFooter>
                <DialogClose className={cn(buttonVariants({ size: 'sm', variant: 'ghost' }))}>
                  {t('common.cancel')}
                </DialogClose>
                <Button
                  disabled={reset.isPending}
                  size="sm"
                  type="button"
                  onClick={() =>
                    reset.mutate({ body: { must_change_password: mustChange }, path: { uid: principal.id } })
                  }>
                  {actionLabel}
                </Button>
              </DialogFooter>
            </>
          )}
        </DialogContent>
      </Dialog>
    </section>
  )
}
