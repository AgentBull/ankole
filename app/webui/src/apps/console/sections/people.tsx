import { RiAddLine, RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsoleHumanUser } from '@/console/service'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Input } from '@/uikit/components/input'
import { Spinner } from '@/uikit/components/spinner'
import { TableCell, TableRow } from '@/uikit/components/table'
import { ErrorAlert, SectionHeader, TableCard } from '../shared'

/** Manages human principals that identity-provider setup and authorization checks refer to. */
export function PeoplePage() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const humans = useQuery({
    queryKey: ['console-human-users'],
    queryFn: () => unwrap(api.console['human-users'].get())
  })
  const [uid, setUid] = useState('')
  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [selectedHumanUid, setSelectedHumanUid] = useState<string | null>(null)
  const selectedHuman = humans.data?.humans.find(human => human.principal.uid === selectedHumanUid)
  const create = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['human-users'].post({
          uid,
          displayName: displayName.trim() ? displayName : null,
          email: email.trim() ? email : null,
          phone: phone.trim() ? phone : null
        })
      ),
    onSuccess: () => {
      setUid('')
      setDisplayName('')
      setEmail('')
      setPhone('')
      queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
    }
  })
  const update = useMutation({
    mutationFn: () =>
      unwrap(
        api.console['human-users']({ principalUid: selectedHumanUid ?? '' }).put({
          displayName: displayName.trim() ? displayName : null,
          email: email.trim() ? email : null,
          phone: phone.trim() ? phone : null,
          status: selectedHuman?.principal.status
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
  })
  const toggle = useMutation({
    mutationFn: (human: ConsoleHumanUser) =>
      unwrap(
        api.console['human-users']({ principalUid: human.principal.uid }).put({
          status: human.principal.status === 'active' ? 'disabled' : 'active'
        })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-human-users'] })
  })

  useEffect(() => {
    if (!selectedHuman) return
    setUid(selectedHuman.principal.uid)
    setDisplayName(selectedHuman.principal.displayName ?? '')
    setEmail(selectedHuman.humanUser.email ?? '')
    setPhone(selectedHuman.humanUser.phone ?? '')
  }, [selectedHuman])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.people.title')} description={t('console.people.description')} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">
            {selectedHumanUid ? t('console.people.edit_title') : t('console.people.create_title')}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3 md:grid-cols-[1fr_1fr_1fr_1fr_auto_auto]"
            onSubmit={event => {
              event.preventDefault()
              selectedHumanUid ? update.mutate() : create.mutate()
            }}>
            <Input
              placeholder={t('console.people.uid_placeholder')}
              value={uid}
              disabled={Boolean(selectedHumanUid)}
              onChange={event => setUid(event.target.value)}
            />
            <Input
              placeholder={t('console.people.display_name_placeholder')}
              value={displayName}
              onChange={event => setDisplayName(event.target.value)}
            />
            <Input
              placeholder={t('console.people.email_placeholder')}
              value={email}
              onChange={event => setEmail(event.target.value)}
            />
            <Input
              placeholder={t('console.people.phone_placeholder')}
              value={phone}
              onChange={event => setPhone(event.target.value)}
            />
            <Button type="submit" disabled={!uid.trim() || create.isPending || update.isPending}>
              {create.isPending || update.isPending ? <Spinner /> : selectedHumanUid ? <RiSaveLine /> : <RiAddLine />}
              {selectedHumanUid ? t('console.save') : t('console.create')}
            </Button>
            <Button
              type="button"
              variant="ghost"
              onClick={() => {
                setSelectedHumanUid(null)
                setUid('')
                setDisplayName('')
                setEmail('')
                setPhone('')
              }}>
              {t('console.clear')}
            </Button>
          </form>
          <ErrorAlert error={create.error ?? update.error} title={t('console.people.save_failed')} />
        </CardContent>
      </Card>
      <TableCard
        loading={humans.isPending}
        error={humans.error}
        empty={(humans.data?.humans.length ?? 0) === 0}
        columns={[
          t('console.people.column_uid'),
          t('console.people.column_name'),
          t('console.people.column_email'),
          t('console.people.column_status'),
          t('console.actions')
        ]}>
        {(humans.data?.humans ?? []).map(human => (
          <TableRow key={human.principal.uid}>
            <TableCell className="font-mono text-xs">{human.principal.uid}</TableCell>
            <TableCell>{human.principal.displayName ?? '-'}</TableCell>
            <TableCell>{human.humanUser.email ?? '-'}</TableCell>
            <TableCell>
              <Badge variant={human.principal.status === 'active' ? 'default' : 'secondary'}>
                {human.principal.status}
              </Badge>
            </TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button size="sm" variant="outline" onClick={() => setSelectedHumanUid(human.principal.uid)}>
                  {t('console.edit')}
                </Button>
                <Button size="sm" variant="outline" disabled={toggle.isPending} onClick={() => toggle.mutate(human)}>
                  {human.principal.status === 'active' ? t('console.disable') : t('console.people.activate')}
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
