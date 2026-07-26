import {
  Badge,
  Button,
  buttonVariants,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  Skeleton
} from '@ankole/uikit'
import { RiExternalLinkLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useSearchParams } from 'react-router'
import {
  ankoleWebAgentLibrarySkillOverlayControllerIndexOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { AgentLibrarySkillOverlayItem } from '../api/generated/types.gen'
import { ErrorBlock } from '../console-primitives'
import { PageHeader, RefreshButton } from '../console-list-page'
import { defaultBrainOwnerUID, setBrainFilter } from '../state/brain-editor-model'
import { BrainOwnerField, BrainTaskNavigation, formatBrainDate } from './brain-shared'

// Skill experience is Agent Library state that dreaming writes, so this surface
// stays read-only and hands editing back to the Agent Library page that owns it.
export function BrainSkillExperiencePage() {
  const { t } = useTranslation()
  const [searchParams, setSearchParams] = useSearchParams()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const agents = (principals.data?.principals ?? []).filter(principal => principal.type === 'agent')
  const requestedOwnerUID = searchParams.get('owner')
  const ownerUID =
    requestedOwnerUID && agents.some(agent => agent.uid === requestedOwnerUID)
      ? requestedOwnerUID
      : defaultBrainOwnerUID(agents)
  const overlays = useQuery({
    ...ankoleWebAgentLibrarySkillOverlayControllerIndexOptions({ path: { agent_uid: ownerUID } }),
    enabled: Boolean(ownerUID)
  })
  const items = overlays.data?.skill_overlays ?? []

  useEffect(() => {
    if (searchParams.get('owner') === ownerUID || !ownerUID) return
    const next = new URLSearchParams(searchParams)
    next.set('owner', ownerUID)
    setSearchParams(next, { replace: true })
  }, [ownerUID, searchParams, setSearchParams])

  return (
    <div className="grid min-w-0 gap-6">
      <PageHeader
        title={t('console.brain.experience_title')}
        description={t('console.brain.experience_description')}
        actions={<RefreshButton />}
      />
      <BrainTaskNavigation active="experience" ownerUID={ownerUID} />

      <div className="grid grid-cols-1 gap-4 border border-border bg-card p-4 md:grid-cols-2">
        <BrainOwnerField
          ownerUID={ownerUID}
          principals={agents}
          onChange={value => setSearchParams(setBrainFilter(searchParams, 'owner', value), { replace: true })}
        />
      </div>

      <ErrorBlock error={overlays.error ?? principals.error} />
      {overlays.isLoading || principals.isLoading ? (
        <Skeleton className="h-48 w-full" />
      ) : items.length === 0 ? (
        <div className="grid gap-1 border border-dashed border-border p-8 text-center">
          <h3 className="text-sm font-medium">{t('console.brain.experience_empty_title')}</h3>
          <p className="text-sm text-muted-foreground">{t('console.brain.experience_empty_description')}</p>
        </div>
      ) : (
        <div className="grid gap-4">
          {items.map(item => (
            <SkillExperienceCard key={item.skill_name} item={item} ownerUID={ownerUID} />
          ))}
        </div>
      )}
    </div>
  )
}

function SkillExperienceCard({ item, ownerUID }: { item: AgentLibrarySkillOverlayItem; ownerUID: string }) {
  const { t } = useTranslation()
  const scope = `scope=${encodeURIComponent(ownerUID)}`
  const editHref = item.agent_plugin_id
    ? `/agent-library/agent-plugins/${item.agent_plugin_id}?${scope}`
    : `/agent-library?${scope}`

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="grid min-w-0 gap-1">
            <CardTitle className="flex flex-wrap items-center gap-2 normal-case">
              {item.skill_name}
              {item.effective_enabled ? null : (
                <Badge variant="outline">{t('console.brain.experience_skill_disabled')}</Badge>
              )}
            </CardTitle>
            <CardDescription>{item.description ?? '—'}</CardDescription>
          </div>
          <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to={editHref}>
            <RiExternalLinkLine />
            {t('console.brain.experience_manage')}
          </Link>
        </div>
      </CardHeader>
      <CardContent className="grid gap-2">
        <pre className="max-h-80 overflow-auto whitespace-pre-wrap border border-border bg-muted p-3 text-sm leading-6">
          {item.text}
        </pre>
        <span className="text-xs text-muted-foreground">
          {t('console.brain.experience_updated')} {formatBrainDate(item.updated_at)}
        </span>
      </CardContent>
    </Card>
  )
}
