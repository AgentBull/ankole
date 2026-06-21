import { RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Input } from '@/uikit/components/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { Spinner } from '@/uikit/components/spinner'
import { TableCell, TableRow } from '@/uikit/components/table'
import { formatDate, useAgentsQuery } from '../helpers'
import { AgentSelector, ErrorAlert, SectionHeader, TableCard } from '../shared'

/** Shows computer-worker liveness and lets operators pin an agent to a specific worker. */
export function WorkersPage() {
  const { t } = useTranslation()
  const agents = useAgentsQuery()
  const queryClient = useQueryClient()
  const [agentUid, setAgentUid] = useState('')
  const [workerId, setWorkerId] = useState('')
  const [reason, setReason] = useState('')
  const workers = useQuery({
    queryKey: ['console-computer-workers'],
    queryFn: () => unwrap(api.console.computer.workers.get())
  })
  const pin = useMutation({
    mutationFn: () =>
      unwrap(
        api.console.computer.pins.post({
          agentUid,
          workerId,
          reason: reason.trim() ? reason : null
        })
      ),
    onSuccess: () => {
      setReason('')
      queryClient.invalidateQueries({ queryKey: ['console-computer-workers'] })
    }
  })
  const unpin = useMutation({
    mutationFn: () => unwrap(api.console.computer.pins({ agentUid }).delete()),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-computer-workers'] })
  })

  useEffect(() => {
    if (!agentUid && agents.data?.agents[0]) setAgentUid(agents.data.agents[0].uid)
  }, [agentUid, agents.data?.agents])

  useEffect(() => {
    if (!workerId && workers.data?.workers[0]) setWorkerId(workers.data.workers[0].workerId)
  }, [workerId, workers.data?.workers])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.workers.title')} description={t('console.workers.description')} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">{t('console.workers.pin_title')}</CardTitle>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3 md:grid-cols-[1fr_1fr_1fr_auto_auto]"
            onSubmit={event => {
              event.preventDefault()
              pin.mutate()
            }}>
            <AgentSelector agents={agents.data?.agents ?? []} value={agentUid} onChange={setAgentUid} />
            <Select value={workerId} onValueChange={next => setWorkerId(next ?? workerId)}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={t('console.workers.worker_placeholder')} />
              </SelectTrigger>
              <SelectContent>
                {(workers.data?.workers ?? []).map(worker => (
                  <SelectItem key={worker.workerId} value={worker.workerId}>
                    {worker.workerId}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              placeholder={t('console.workers.reason_placeholder')}
              value={reason}
              onChange={event => setReason(event.target.value)}
            />
            <Button type="submit" disabled={!agentUid || !workerId || pin.isPending}>
              {pin.isPending ? <Spinner /> : <RiSaveLine />}
              {t('console.workers.pin_button')}
            </Button>
            <Button
              type="button"
              variant="outline"
              disabled={!agentUid || unpin.isPending}
              onClick={() => unpin.mutate()}>
              {t('console.workers.unpin_button')}
            </Button>
          </form>
          <ErrorAlert error={pin.error ?? unpin.error} title={t('console.workers.pin_failed')} />
        </CardContent>
      </Card>
      <TableCard
        loading={workers.isPending}
        error={workers.error}
        empty={(workers.data?.workers.length ?? 0) === 0}
        columns={[
          t('console.workers.column_worker'),
          t('console.workers.column_status'),
          t('console.workers.column_base_url'),
          t('console.workers.column_features'),
          t('console.workers.column_heartbeat')
        ]}>
        {(workers.data?.workers ?? []).map(worker => (
          <TableRow key={worker.workerId}>
            <TableCell className="font-mono text-xs">{worker.workerId}</TableCell>
            <TableCell>
              <Badge variant={worker.status === 'ready' ? 'default' : 'secondary'}>{worker.status}</Badge>
            </TableCell>
            <TableCell className="max-w-[280px] truncate">{worker.baseUrl}</TableCell>
            <TableCell>{worker.features.join(', ') || '-'}</TableCell>
            <TableCell>{formatDate(worker.lastHeartbeatAt)}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
