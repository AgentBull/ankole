import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  Input,
  Label,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { ErrorBlock } from './error-block'
import { PrincipalRenameModel } from './state/principal-rename'

type RenameResult = { uid: string; base_repair_error?: string | null }
type RenameMutation = {
  isPending: boolean
  error: unknown
  reset: () => void
  mutateAsync: (uid: string) => Promise<RenameResult>
}

export function PrincipalRename({
  uid,
  agent = false,
  mutation
}: {
  uid: string
  agent?: boolean
  mutation: RenameMutation
}) {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(PrincipalRenameModel)
  const inputID = useId()
  return (
    <>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onClick={() => {
          mutation.reset()
          model.start(uid)
        }}>
        {t('principal_rename.action')}
      </Button>
      <Dialog
        open={model.open.value}
        onOpenChange={open => {
          if (!mutation.isPending) model.open.value = open
        }}>
        <DialogContent>
          <DialogTitle>{t('principal_rename.title', { uid })}</DialogTitle>
          <DialogDescription>
            {t(agent ? 'principal_rename.agent_hint' : 'principal_rename.human_hint')}
          </DialogDescription>
          <form
            className="grid gap-4"
            onSubmit={async event => {
              event.preventDefault()
              event.stopPropagation()
              if (mutation.isPending) return
              try {
                const result = await mutation.mutateAsync(model.newUID.value.trim())
                model.open.value = false
                if (result.base_repair_error) {
                  toast.warning(
                    t('principal_rename.base_pending', { old: uid, uid: result.uid, error: result.base_repair_error })
                  )
                } else toast.success(t('principal_rename.saved', { uid: result.uid }))
              } catch {
                // The mutation owns the error displayed below and keeps this draft available for retry.
              }
            }}>
            <ErrorBlock error={mutation.error} />
            <div className="grid gap-2">
              <Label htmlFor={inputID}>{t('principal_rename.new_uid')}</Label>
              <Input
                id={inputID}
                required
                autoCapitalize="none"
                autoComplete="off"
                autoCorrect="off"
                spellCheck={false}
                maxLength={agent ? 96 : undefined}
                pattern={agent ? '[a-z0-9][a-z0-9._@+\\-]{0,95}' : undefined}
                value={model.newUID.value}
                onChange={event => {
                  mutation.reset()
                  model.newUID.value = event.target.value.toLowerCase()
                }}
              />
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={mutation.isPending}
                onClick={() => {
                  model.open.value = false
                }}>
                {t('common.cancel')}
              </Button>
              <Button type="submit" disabled={mutation.isPending}>
                {t('principal_rename.action')}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </>
  )
}
