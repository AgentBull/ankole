import { Badge, Button, Input, Label, toast } from '@ankole/uikit'
import { queryOptions, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys } from './api'
import { listPodRunnerDevices, registerPodRunnerDevice, revokePodRunnerDevice } from './api/generated/sdk.gen'
import { ContentError } from './content-primitives'
import { SettingsSection } from './settings-layout'

export const runnerDevicesQuery = () =>
  queryOptions({
    queryKey: [...podKeys.agents, 'runner-devices'],
    queryFn: () => listPodRunnerDevices(),
    refetchInterval: query => (query.state.data?.devices.length ? 10_000 : false)
  })

export function RunnerDevicesSettings() {
  const { t } = useTranslation()
  const client = useQueryClient()
  const [name, setName] = useState('')
  const devices = useQuery(runnerDevicesQuery())
  const register = useMutation({
    mutationFn: (name: string) => registerPodRunnerDevice({ body: { data: { name } } }),
    onSuccess: () => {
      setName('')
      void client.invalidateQueries({ queryKey: runnerDevicesQuery().queryKey })
    }
  })
  const revoke = useMutation({
    mutationFn: (id: string) => revokePodRunnerDevice({ path: { id } }),
    onSuccess: (_, id) => {
      if (register.data?.id === id) register.reset()
      void client.invalidateQueries({ queryKey: runnerDevicesQuery().queryKey })
    }
  })
  const pairing = register.data
  const stillPairing =
    !pairing || !devices.data?.devices.some(device => device.id === pairing.id && device.status !== 'pairing')
  const command = pairing && stillPairing && `ankole-worker pair --url ${pairing.url} --code ${pairing.code}`
  return (
    <SettingsSection title={t('pod.runner.title')} description={t('pod.runner.description')}>
      <div className="grid gap-4">
        <ContentError error={devices.error ?? register.error ?? revoke.error} />
        <form
          className="flex flex-wrap items-end gap-2"
          onSubmit={event => {
            event.preventDefault()
            if (name.trim()) register.mutate(name.trim())
          }}>
          <div className="grid min-w-48 gap-1.5">
            <Label htmlFor="runner-device-name">{t('pod.runner.device_name')}</Label>
            <Input
              id="runner-device-name"
              required
              maxLength={80}
              value={name}
              onChange={event => setName(event.target.value)}
            />
          </div>
          <Button type="submit" disabled={!name.trim() || register.isPending}>
            {t('pod.runner.connect')}
          </Button>
        </form>
        {command && pairing && (
          <div className="grid gap-2 rounded-lg border border-border bg-muted/30 p-3">
            <p className="text-sm">{t('pod.runner.pair_instructions')}</p>
            <code className="break-all text-xs">{command}</code>
            <div>
              <Button
                size="sm"
                variant="outline"
                onClick={async () => {
                  await navigator.clipboard.writeText(command)
                  toast.success(t('pod.runner.copied'))
                }}>
                {t('pod.runner.copy')}
              </Button>
            </div>
          </div>
        )}
        {devices.data?.devices.map(device => (
          <div
            key={device.id}
            className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-3">
            <div className="flex min-w-0 flex-wrap items-center gap-2">
              <span className="break-all text-sm font-medium">{device.name}</span>
              <Badge variant="outline">{t(`pod.runner.status_${device.status}`)}</Badge>
              <span className="break-all text-xs text-muted-foreground">
                {device.bindings.map(binding => binding.agentUID).join(', ')}
              </span>
            </div>
            <Button size="sm" variant="outline" disabled={revoke.isPending} onClick={() => revoke.mutate(device.id)}>
              {t('pod.runner.disconnect')}
            </Button>
          </div>
        ))}
      </div>
    </SettingsSection>
  )
}
