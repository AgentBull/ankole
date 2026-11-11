import {
  Badge,
  Button,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  toast
} from '@ankole/uikit'
import { queryOptions, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { podKeys } from './api'
import {
  bindPodRunnerDevice,
  listPodRunnerDevices,
  registerPodRunnerDevice,
  revokePodRunnerDevice
} from './api/generated/sdk.gen'
import type { ListPodRunnerDevicesResponse } from './api/generated/types.gen'
import { ContentError } from './content-primitives'
import { SettingsSection } from './settings-layout'

type RunnerDeviceItem = ListPodRunnerDevicesResponse['devices'][number]
type RunnerColleagueItem = ListPodRunnerDevicesResponse['colleagues'][number]

export function unboundRunnerColleagues(
  device: Pick<RunnerDeviceItem, 'bindings'>,
  colleagues: readonly RunnerColleagueItem[]
): RunnerColleagueItem[] {
  const boundUIDs = new Set(device.bindings.map(binding => binding.agentUID))
  return colleagues.filter(colleague => !boundUIDs.has(colleague.uid))
}

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
  const [selectedByDevice, setSelectedByDevice] = useState<Record<string, string>>({})
  const devices = useQuery(runnerDevicesQuery())
  const register = useMutation({
    mutationFn: (name: string) => registerPodRunnerDevice({ body: { data: { name } } }),
    onSuccess: () => {
      setName('')
      void client.invalidateQueries({ queryKey: runnerDevicesQuery().queryKey })
    }
  })
  const bind = useMutation({
    mutationFn: ({ id, agentUID }: { id: string; agentUID: string }) =>
      bindPodRunnerDevice({ path: { id }, body: { data: { agentUID } } }),
    onSuccess: (_, { id }) => {
      setSelectedByDevice(current => {
        const next = { ...current }
        delete next[id]
        return next
      })
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
  const colleagues = devices.data?.colleagues ?? []
  const pairing = register.data
  const stillPairing =
    !pairing || !devices.data?.devices.some(device => device.id === pairing.id && device.status !== 'pairing')
  const command = pairing && stillPairing && `ankole-worker pair --url ${pairing.url} --code ${pairing.code}`
  return (
    <SettingsSection title={t('pod.runner.title')} description={t('pod.runner.description')}>
      <div className="grid gap-4">
        <ContentError error={devices.error ?? register.error ?? bind.error ?? revoke.error} />
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
        {devices.data?.devices.map(device => {
          const unbound = unboundRunnerColleagues(device, colleagues)
          const storedSelection = selectedByDevice[device.id]
          const selectedUID =
            storedSelection && unbound.some(colleague => colleague.uid === storedSelection)
              ? storedSelection
              : (unbound[0]?.uid ?? '')
          const isBindingThisDevice = bind.isPending && bind.variables?.id === device.id
          return (
            <div key={device.id} className="grid gap-2.5 border-t border-border pt-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <span className="break-all text-sm font-medium">{device.name}</span>
                  <Badge variant={device.status === 'online' ? 'success' : 'outline'}>
                    {t(`pod.runner.status_${device.status}`)}
                  </Badge>
                </div>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={revoke.isPending}
                  onClick={() => revoke.mutate(device.id)}>
                  {t('pod.runner.disconnect')}
                </Button>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs text-muted-foreground">{t('pod.runner.colleagues_label')}</span>
                {device.bindings.map(binding => {
                  const title = binding.displayName || binding.agentUID
                  return (
                    <div
                      key={binding.agentUID}
                      className="inline-flex flex-wrap items-center gap-1.5 rounded-md border border-border bg-muted/20 px-2 py-1 text-xs">
                      <span className="font-medium">{title}</span>
                      {binding.displayName && binding.displayName !== binding.agentUID && (
                        <span className="text-muted-foreground">@{binding.agentUID}</span>
                      )}
                      <Badge
                        variant={
                          binding.status === 'connected'
                            ? 'success'
                            : binding.status === 'draining'
                              ? 'warning'
                              : 'outline'
                        }>
                        {t(`pod.runner.binding_status_${binding.status}`, { defaultValue: binding.status })}
                      </Badge>
                    </div>
                  )
                })}
              </div>
              {unbound.length > 0 ? (
                <div className="flex flex-wrap items-center gap-2">
                  <Select
                    value={selectedUID}
                    onValueChange={value => {
                      if (value) setSelectedByDevice(current => ({ ...current, [device.id]: value }))
                    }}>
                    <SelectTrigger
                      id={`runner-bind-${device.id}`}
                      aria-label={t('pod.runner.bind_colleague')}
                      className="h-8 min-w-48 text-xs">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {unbound.map(colleague => (
                        <SelectItem key={colleague.uid} value={colleague.uid}>
                          {colleague.displayName !== colleague.uid
                            ? `${colleague.displayName} (@${colleague.uid})`
                            : colleague.uid}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={!selectedUID || isBindingThisDevice}
                    onClick={() => {
                      if (selectedUID) bind.mutate({ id: device.id, agentUID: selectedUID })
                    }}>
                    {t('pod.runner.bind_action')}
                  </Button>
                </div>
              ) : (
                colleagues.length > 0 && (
                  <span className="text-xs text-muted-foreground">{t('pod.runner.all_colleagues_bound')}</span>
                )
              )}
            </div>
          )
        })}
      </div>
    </SettingsSection>
  )
}
