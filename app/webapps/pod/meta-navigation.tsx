import { Avatar, AvatarFallback, AvatarImage, Button } from '@ankole/uikit'
import { RiArrowRightSLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useId, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { linkTarget } from '../common/router'
import { metaAgentsQuery, metaBrainQuery, metaSkillsQuery, metaSkillQuery } from './meta-api'

export function MetaLink({ to, children, onNavigate }: { to: string; children: ReactNode; onNavigate?: () => void }) {
  return (
    <Link
      {...linkTarget(to)}
      onClick={onNavigate}
      activeOptions={{ exact: true }}
      className="nav-row flex min-w-0 flex-1 items-center gap-1.5 truncate rounded-control px-2 py-1">
      {children}
    </Link>
  )
}
function Branch({
  to,
  label,
  children,
  onNavigate
}: {
  to?: string
  label: string
  children: ReactNode
  onNavigate?: () => void
}) {
  const [open, setOpen] = useState(false)
  const id = useId()
  return (
    <li>
      <div className="flex items-center">
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label={label}
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen(!open)}>
          <RiArrowRightSLine aria-hidden className={open ? 'size-4 rotate-90' : 'size-4'} />
        </Button>
        {to ? (
          <MetaLink to={to} onNavigate={onNavigate}>
            {label}
          </MetaLink>
        ) : (
          <button
            type="button"
            className="nav-row min-w-0 flex-1 text-left"
            aria-expanded={open}
            aria-controls={id}
            onClick={() => setOpen(!open)}>
            {label}
          </button>
        )}
      </div>
      <ul id={id} hidden={!open} className="ml-3 border-l border-border pl-2">
        {open && children}
      </ul>
    </li>
  )
}
export function MetaNavigation({ onNavigate }: { onNavigate?: () => void }) {
  const { t } = useTranslation()
  return (
    <nav aria-label="Meta Ankole">
      <ul>
        <Branch to="/meta/brain" label={t('pod.meta.brain')} onNavigate={onNavigate}>
          <BrainTree onNavigate={onNavigate} />
          <li>
            <MetaLink to="/meta/brain?view=favorites" onNavigate={onNavigate}>
              {t('pod.content.favorites')}
            </MetaLink>
          </li>
          <li>
            <MetaLink to="/meta/brain?view=trash" onNavigate={onNavigate}>
              {t('pod.content.trash')}
            </MetaLink>
          </li>
        </Branch>
        <Branch to="/meta/skills" label={t('pod.meta.skills')} onNavigate={onNavigate}>
          <SkillsTree onNavigate={onNavigate} />
        </Branch>
        <Branch to="/meta/agents" label={t('pod.meta.agents')} onNavigate={onNavigate}>
          <AgentsTree onNavigate={onNavigate} />
        </Branch>
      </ul>
    </nav>
  )
}
function BrainTree({ onNavigate }: { onNavigate?: () => void }) {
  const graph = useQuery(metaBrainQuery())
  return graph.data?.categories.map(category => (
    <Branch
      key={category.id}
      to={`/meta/brain?category=${encodeURIComponent(category.name)}`}
      label={category.name}
      onNavigate={onNavigate}>
      {graph.data.nodes
        .filter(node => node.slug.startsWith(`${category.name}/`))
        .map(node => (
          <li key={node.id}>
            <MetaLink to={`/meta/brain/${node.id}`} onNavigate={onNavigate}>
              {node.title}
            </MetaLink>
          </li>
        ))}
    </Branch>
  ))
}
function SkillsTree({ onNavigate }: { onNavigate?: () => void }) {
  const skills = useQuery(metaSkillsQuery())
  return skills.data?.skills.map(skill => (
    <Branch key={skill.id} to={`/meta/skills/${skill.slug}`} label={skill.slug} onNavigate={onNavigate}>
      <SkillFiles slug={skill.slug} onNavigate={onNavigate} />
    </Branch>
  ))
}
function SkillFiles({ slug, onNavigate }: { slug: string; onNavigate?: () => void }) {
  const skill = useQuery(metaSkillQuery(slug))
  return (
    <SkillFileTree
      slug={slug}
      paths={['SKILL.md', ...(skill.data?.files.map(file => file.relative_path) ?? [])]}
      onNavigate={onNavigate}
    />
  )
}
function SkillFileTree({
  slug,
  paths,
  prefix = '',
  onNavigate
}: {
  slug: string
  paths: string[]
  prefix?: string
  onNavigate?: () => void
}) {
  const names = [...new Set(paths.map(path => path.slice(prefix.length).split('/')[0]))].sort()
  return names.map(name => {
    const path = prefix + name
    const children = paths.filter(candidate => candidate.startsWith(`${path}/`))
    const to = `/meta/skills/${slug}?file=${encodeURIComponent(path)}`
    return children.length > 0 ? (
      <Branch key={path} label={name} onNavigate={onNavigate}>
        <SkillFileTree slug={slug} paths={children} prefix={`${path}/`} onNavigate={onNavigate} />
      </Branch>
    ) : (
      <li key={path}>
        <MetaLink to={to} onNavigate={onNavigate}>
          {name}
        </MetaLink>
      </li>
    )
  })
}
function AgentsTree({ onNavigate }: { onNavigate?: () => void }) {
  const { t } = useTranslation()
  const agents = useQuery(metaAgentsQuery())
  return (
    <>
      {agents.data?.agents
        .filter(agent => agent.type === 'ai_colleague')
        .map(agent => (
          <li key={agent.uid}>
            <MetaLink to={`/meta/agents/colleagues/${agent.uid}`} onNavigate={onNavigate}>
              <Avatar className="size-5 shrink-0">
                <AvatarImage src={agent.avatar_url ?? undefined} />
                <AvatarFallback>{agent.display_name.slice(0, 1)}</AvatarFallback>
              </Avatar>
              <span className="truncate">{agent.display_name}</span>
            </MetaLink>
          </li>
        ))}
      <li className="mt-2 border-t border-border pt-2">
        <MetaLink to="/meta/agents/assistant" onNavigate={onNavigate}>
          {t('pod.meta.assistant')}
        </MetaLink>
      </li>
      <li>
        <MetaLink to="/meta/agents/global" onNavigate={onNavigate}>
          {t('pod.meta.global')}
        </MetaLink>
      </li>
    </>
  )
}
