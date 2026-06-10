import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Badge } from '@/uikit/components/badge'
import { Button } from '@/uikit/components/button'
import { TableCell, TableRow } from '@/uikit/components/table'
import { useAgentsQuery } from '../helpers'
import { AgentSelector, SectionHeader, TableCard } from '../shared'

export function SkillsPage() {
  const { t } = useTranslation()
  const agents = useAgentsQuery()
  const [selectedAgentUid, setSelectedAgentUid] = useState<string | null>(null)
  const selectedUid = selectedAgentUid ?? agents.data?.agents[0]?.uid ?? ''
  const librarySkills = useQuery({
    queryKey: ['console-library-skills'],
    queryFn: () => unwrap(api.console['library-skills'].get())
  })
  const agentSkills = useQuery({
    queryKey: ['console-agent-skills', selectedUid],
    enabled: Boolean(selectedUid),
    queryFn: () => unwrap(api.console.agents({ uid: selectedUid }).skills.get())
  })
  const queryClient = useQueryClient()
  const toggle = useMutation({
    mutationFn: (input: { skillName: string; enabled: boolean }) =>
      unwrap(
        api.console.agents({ uid: selectedUid }).skills({ skillName: input.skillName }).put({ enabled: input.enabled })
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['console-agent-skills', selectedUid] })
  })
  const effectiveNames = new Set((agentSkills.data?.skills ?? []).map(skill => skill.name))

  useEffect(() => {
    if (!selectedAgentUid && agents.data?.agents[0]) setSelectedAgentUid(agents.data.agents[0].uid)
  }, [agents.data?.agents, selectedAgentUid])

  return (
    <div className="flex w-full max-w-7xl flex-col gap-6">
      <SectionHeader title={t('console.skills.title')} description={t('console.skills.description')} />
      <AgentSelector agents={agents.data?.agents ?? []} value={selectedUid} onChange={setSelectedAgentUid} />
      <TableCard
        loading={librarySkills.isPending || agentSkills.isPending}
        error={librarySkills.error ?? agentSkills.error}
        empty={(librarySkills.data?.skills.length ?? 0) === 0}
        columns={[
          t('console.skills.column_skill'),
          t('console.skills.column_source'),
          t('console.skills.column_default'),
          t('console.skills.column_effective'),
          t('console.actions')
        ]}>
        {(librarySkills.data?.skills ?? []).map(skill => (
          <TableRow key={skill.id}>
            <TableCell>
              <div className="grid gap-1">
                <span className="font-medium">{skill.name}</span>
                <span className="text-xs text-muted-foreground">{skill.description}</span>
              </div>
            </TableCell>
            <TableCell>{skill.sourceKind}</TableCell>
            <TableCell>{skill.defaultEnabled ? t('console.skills.on') : t('console.skills.off')}</TableCell>
            <TableCell>
              <Badge variant={effectiveNames.has(skill.name) ? 'default' : 'secondary'}>
                {effectiveNames.has(skill.name) ? t('console.badge_enabled') : t('console.badge_disabled')}
              </Badge>
            </TableCell>
            <TableCell>
              <div className="flex justify-end gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  disabled={!selectedUid || toggle.isPending}
                  onClick={() => toggle.mutate({ skillName: skill.name, enabled: !effectiveNames.has(skill.name) })}>
                  {effectiveNames.has(skill.name) ? t('console.disable') : t('console.enable')}
                </Button>
              </div>
            </TableCell>
          </TableRow>
        ))}
      </TableCard>
    </div>
  )
}
