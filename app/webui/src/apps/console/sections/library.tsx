import { RiSaveLine } from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import type { ConsoleAgentLibraryEntry } from '@/console/service'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { Spinner } from '@/uikit/components/spinner'
import { TableCell, TableRow } from '@/uikit/components/table'
import { Textarea } from '@/uikit/components/textarea'
import { formatDate, useAgentsQuery } from '../helpers'
import { AgentSelector, ErrorAlert, SectionHeader, TableCard } from '../shared'

export function LibraryEntriesPage() {
  const { t } = useTranslation()
  const agents = useAgentsQuery()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const entries = useQuery({
    queryKey: ['console-agent-library-entries', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid })['library-entries'].get())
  })
  const soul = useQuery({
    queryKey: ['console-agent-soul', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid }).soul.get())
  })
  const mission = useQuery({
    queryKey: ['console-agent-mission', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid }).mission.get())
  })
  const [soulContent, setSoulContent] = useState('')
  const [missionContent, setMissionContent] = useState('')
  const queryClient = useQueryClient()
  const saveSoul = useMutation({
    mutationFn: () => unwrap(api.console.agents({ uid: selectedUid }).soul.put({ content: soulContent })),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['console-agent-soul', selectedUid] })
      queryClient.invalidateQueries({ queryKey: ['console-agent-library-entries', selectedUid] })
    }
  })
  const saveMission = useMutation({
    mutationFn: () => unwrap(api.console.agents({ uid: selectedUid }).mission.put({ content: missionContent })),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['console-agent-mission', selectedUid] })
      queryClient.invalidateQueries({ queryKey: ['console-agent-library-entries', selectedUid] })
    }
  })

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  useEffect(() => {
    setSoulContent('')
    setMissionContent('')
  }, [selectedUid])

  useEffect(() => {
    if (soul.data) setSoulContent(soul.data.content ?? '')
  }, [soul.data])

  useEffect(() => {
    if (mission.data) setMissionContent(mission.data.content ?? '')
  }, [mission.data])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.library.title')} description={t('console.library.description')} />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">SOUL.md</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3">
          <Textarea
            value={soulContent}
            onChange={event => setSoulContent(event.target.value)}
            className="min-h-56 font-mono"
          />
          <div className="flex items-center gap-2">
            <Button disabled={!selectedUid || saveSoul.isPending} onClick={() => saveSoul.mutate()}>
              {saveSoul.isPending ? <Spinner /> : <RiSaveLine />}
              {t('console.save')}
            </Button>
            <ErrorAlert error={saveSoul.error ?? soul.error} title={t('console.library.soul_save_failed')} />
          </div>
        </CardContent>
      </Card>
      <Card size="sm">
        <CardHeader>
          <CardTitle className="text-base">MISSION.md</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-3">
          <Textarea
            value={missionContent}
            onChange={event => setMissionContent(event.target.value)}
            className="min-h-40 font-mono"
          />
          <div className="flex items-center gap-2">
            <Button disabled={!selectedUid || saveMission.isPending} onClick={() => saveMission.mutate()}>
              {saveMission.isPending ? <Spinner /> : <RiSaveLine />}
              {t('console.save')}
            </Button>
            <ErrorAlert error={saveMission.error ?? mission.error} title={t('console.library.mission_save_failed')} />
          </div>
        </CardContent>
      </Card>
      <TableCard
        loading={entries.isPending}
        error={entries.error}
        empty={(entries.data?.entries.length ?? 0) === 0}
        columns={[
          t('console.library.column_path'),
          t('console.library.column_source'),
          t('console.enabled'),
          t('console.library.column_version'),
          t('console.library.column_updated')
        ]}>
        {(entries.data?.entries ?? []).map((entry: ConsoleAgentLibraryEntry) => (
          <TableRow key={entry.id}>
            <TableCell className="font-mono text-xs">{entry.virtualPath}</TableCell>
            <TableCell>{entry.sourceKind}</TableCell>
            <TableCell>{entry.enabled ? t('console.yes') : t('console.no')}</TableCell>
            <TableCell>{entry.version}</TableCell>
            <TableCell>{formatDate(entry.updatedAt)}</TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
