import { Button, Input, Label } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { previewInvitation, resolvePodLogin } from '../common/api/generated/sdk.gen'
import { ErrorBlock } from '../common/error-block'

import { JoinSpaceModel, invitationToken } from './state/join-space'

export function JoinSpaceForm() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(JoinSpaceModel)
  const slugID = useId()
  const invitationID = useId()
  const login = useMutation({
    mutationFn: () => resolvePodLogin({ body: { data: { slug: model.slug.value.trim() } } }),
    onSuccess: result => window.location.assign(result.loginURL)
  })
  const invitation = useMutation({
    mutationFn: async () => {
      const token = invitationToken(model.invitation.value, window.location.origin)
      await previewInvitation({ path: { token } })
      return token
    },
    onSuccess: token => window.location.assign(`/join/${encodeURIComponent(token)}`)
  })
  return (
    <section className="grid gap-5 border-t border-border pt-5">
      <h2>{t('auth.join_existing')}</h2>
      <ErrorBlock error={login.error ?? invitation.error} />
      <form
        className="grid gap-3"
        onSubmit={event => {
          event.preventDefault()
          invitation.mutate()
        }}>
        <Label htmlFor={invitationID}>{t('auth.invitation_code')}</Label>
        <Input
          id={invitationID}
          required
          value={model.invitation.value}
          onChange={event => {
            model.invitation.value = event.target.value
          }}
        />
        <Button type="submit" variant="outline" disabled={invitation.isPending}>
          {t('auth.open_invitation')}
        </Button>
      </form>
      <form
        className="grid gap-3"
        onSubmit={event => {
          event.preventDefault()
          login.mutate()
        }}>
        <Label htmlFor={slugID}>{t('auth.space_slug')}</Label>
        <Input
          id={slugID}
          required
          value={model.slug.value}
          onChange={event => {
            model.slug.value = event.target.value
          }}
        />
        <Button type="submit" variant="outline" disabled={login.isPending}>
          {t('auth.enterprise_login')}
        </Button>
      </form>
    </section>
  )
}
