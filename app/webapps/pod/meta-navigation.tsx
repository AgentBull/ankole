import { cn } from '@ankole/uikit'
import {
  RiArrowRightSLine,
  RiBrainLine,
  RiDeleteBinLine,
  RiFileTextLine,
  RiFolderLine,
  RiPuzzle2Line,
  RiRobot2Line,
  RiSettings3Line,
  RiSparklingLine,
  RiStarLine
} from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { Link, createLink, useLocation } from '@tanstack/react-router'
import type { ComponentPropsWithRef, ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { BdiLabel } from '../common/bidi-file-name'
import { podLocation } from '../common/pod-url'
import { linkTarget } from '../common/router'
import { ChatAvatar } from './chat/chat-avatar'
import { metaAgentsQuery, metaBrainQuery, metaSkillQuery, metaSkillsQuery } from './meta-api'
import { PageIcon } from './page-icon'
import { isSidebarSectionActive, type CollapsibleSection } from './state/navigation'
import { usePagesMetadata } from './use-page-metadata'

const MetaSidebarLink = createLink(function MetaSidebarAnchor({
  current,
  ...props
}: ComponentPropsWithRef<'a'> & { current: boolean }) {
  return <a {...props} aria-current={current ? 'page' : undefined} data-status={undefined} />
})

export function isMetaTargetActive(
  to: string,
  pathname: string,
  searchStr: string,
  activeSection?: CollapsibleSection
): boolean {
  if (!isSidebarSectionActive(activeSection, 'meta')) return false
  const target = linkTarget(to)
  if (podLocation(target.to).pathname !== pathname) return false
  const expected = new URLSearchParams(target.search ?? {})
  const actual = new URLSearchParams(searchStr)
  if ([...expected.keys()].length !== [...actual.keys()].length) return false
  for (const [key, value] of expected.entries()) {
    if (actual.get(key) !== value) return false
  }
  return true
}

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

type MetaTreeProps = {
  pathname: string
  searchStr: string
  activeSection?: CollapsibleSection
  expanded: ReadonlySet<string>
  onToggleBranch(key: string): void
  onNavigate?: () => void
}

function MetaBranch({
  branchKey,
  to,
  label,
  icon,
  children,
  pathname,
  searchStr,
  activeSection,
  expanded,
  onToggleBranch,
  onNavigate
}: MetaTreeProps & {
  branchKey: string
  to?: string
  label: string
  icon?: ReactNode
  children: ReactNode
}) {
  const open = expanded.has(branchKey)
  const active = to ? isMetaTargetActive(to, pathname, searchStr, activeSection) : false
  return (
    <li className="min-w-0">
      <div className="nav-row pod-tree-row" data-active={active ? '' : undefined}>
        <button
          type="button"
          className="pod-tree-toggle"
          aria-label={label}
          aria-expanded={open}
          onClick={() => onToggleBranch(branchKey)}>
          <RiArrowRightSLine aria-hidden className={cn(open && 'rotate-90')} />
        </button>
        {to ? (
          <MetaSidebarLink
            {...linkTarget(to)}
            className="pod-tree-link"
            state={{ sidebarSection: 'meta' } as never}
            current={active}
            activeProps={{}}
            onClick={onNavigate}>
            {icon}
            <span className="min-w-0 truncate text-left" dir="auto">
              {label}
            </span>
          </MetaSidebarLink>
        ) : (
          <button
            type="button"
            className="pod-tree-link cursor-pointer text-left"
            aria-expanded={open}
            onClick={() => onToggleBranch(branchKey)}>
            {icon}
            <span className="min-w-0 truncate" dir="auto">
              {label}
            </span>
          </button>
        )}
      </div>
      {open && <ul className="pod-tree-children">{children}</ul>}
    </li>
  )
}

function MetaTreeItem({
  to,
  className,
  children,
  pathname,
  searchStr,
  activeSection,
  onNavigate
}: {
  to: string
  className?: string
  children: ReactNode
  pathname: string
  searchStr: string
  activeSection?: CollapsibleSection
  onNavigate?: () => void
}) {
  const active = isMetaTargetActive(to, pathname, searchStr, activeSection)
  return (
    <li className={cn('min-w-0', className)}>
      <div className="nav-row pod-tree-row" data-active={active ? '' : undefined}>
        <span aria-hidden className="pod-tree-toggle-space" />
        <MetaSidebarLink
          {...linkTarget(to)}
          className="pod-tree-link"
          state={{ sidebarSection: 'meta' } as never}
          current={active}
          activeProps={{}}
          onClick={onNavigate}>
          {children}
        </MetaSidebarLink>
      </div>
    </li>
  )
}

export function MetaNavigation({
  activeSection,
  expanded,
  onToggleBranch,
  onNavigate
}: {
  activeSection?: CollapsibleSection
  expanded: ReadonlySet<string>
  onToggleBranch(key: string): void
  onNavigate?: () => void
}) {
  const { t } = useTranslation()
  const pathname = useLocation({ select: location => location.pathname })
  const searchStr = useLocation({ select: location => location.searchStr })
  const treeProps: MetaTreeProps = {
    pathname,
    searchStr,
    activeSection,
    expanded,
    onToggleBranch,
    onNavigate
  }
  return (
    <ul className="pod-tree">
      <MetaBranch
        branchKey="brain"
        to="/meta/brain"
        label={t('pod.meta.brain')}
        icon={<RiBrainLine aria-hidden className="pod-page-icon" />}
        {...treeProps}>
        <BrainTree {...treeProps} />
      </MetaBranch>
      <MetaBranch
        branchKey="skills"
        to="/meta/skills"
        label={t('pod.meta.skills')}
        icon={<RiPuzzle2Line aria-hidden className="pod-page-icon" />}
        {...treeProps}>
        <SkillsTree {...treeProps} />
      </MetaBranch>
      <MetaBranch
        branchKey="agents"
        to="/meta/agents"
        label={t('pod.meta.agents')}
        icon={<RiRobot2Line aria-hidden className="pod-page-icon" />}
        {...treeProps}>
        <AgentsTree {...treeProps} />
      </MetaBranch>
    </ul>
  )
}

function BrainTree(props: MetaTreeProps) {
  const { t } = useTranslation()
  const graph = useQuery(metaBrainQuery())
  const nodes = usePagesMetadata(graph.data?.nodes ?? [])
  return (
    <>
      {graph.data?.categories.map(category => (
        <MetaBranch
          key={category.id}
          branchKey={`brain:category:${category.id}`}
          to={`/meta/brain?category=${encodeURIComponent(category.name)}`}
          label={category.name}
          icon={<RiFolderLine aria-hidden className="pod-page-icon" />}
          {...props}>
          {nodes
            .filter(node => node.slug.startsWith(`${category.name}/`))
            .map(node => (
              <MetaTreeItem
                key={node.id}
                to={`/meta/brain/${node.id}`}
                pathname={props.pathname}
                searchStr={props.searchStr}
                activeSection={props.activeSection}
                onNavigate={props.onNavigate}>
                <PageIcon
                  page={{
                    type: 'knowledge',
                    icon: (node as { icon?: string | null }).icon ?? null,
                    system_key: null,
                    title: node.title
                  }}
                />
                <span className="min-w-0 truncate text-left" dir="auto">
                  <BdiLabel value={node.title} fallback={t('pod.content.untitled')} />
                </span>
              </MetaTreeItem>
            ))}
        </MetaBranch>
      ))}
      <MetaTreeItem
        to="/meta/brain?view=favorites"
        pathname={props.pathname}
        searchStr={props.searchStr}
        activeSection={props.activeSection}
        onNavigate={props.onNavigate}>
        <RiStarLine aria-hidden className="pod-page-icon" />
        <span className="min-w-0 truncate text-left" dir="auto">
          {t('pod.content.favorites')}
        </span>
      </MetaTreeItem>
      <MetaTreeItem
        to="/meta/brain?view=trash"
        pathname={props.pathname}
        searchStr={props.searchStr}
        activeSection={props.activeSection}
        onNavigate={props.onNavigate}>
        <RiDeleteBinLine aria-hidden className="pod-page-icon" />
        <span className="min-w-0 truncate text-left" dir="auto">
          {t('pod.content.trash')}
        </span>
      </MetaTreeItem>
    </>
  )
}

function SkillsTree(props: MetaTreeProps) {
  const skills = useQuery(metaSkillsQuery())
  return skills.data?.skills.map(skill => (
    <MetaBranch
      key={skill.id}
      branchKey={`skills:package:${skill.id}`}
      to={`/meta/skills/${skill.slug}`}
      label={skill.slug}
      icon={<RiPuzzle2Line aria-hidden className="pod-page-icon" />}
      {...props}>
      <SkillFiles slug={skill.slug} {...props} />
    </MetaBranch>
  ))
}

function SkillFiles({ slug, ...props }: MetaTreeProps & { slug: string }) {
  const skill = useQuery(metaSkillQuery(slug))
  return (
    <SkillFileTree
      slug={slug}
      paths={['SKILL.md', ...(skill.data?.files.map(file => file.relative_path) ?? [])]}
      {...props}
    />
  )
}

function SkillFileTree({
  slug,
  paths,
  prefix = '',
  ...props
}: MetaTreeProps & {
  slug: string
  paths: string[]
  prefix?: string
}) {
  const names = [...new Set(paths.map(path => path.slice(prefix.length).split('/')[0]))].sort()
  return names.map(name => {
    const path = prefix + name
    const children = paths.filter(candidate => candidate.startsWith(`${path}/`))
    const to = `/meta/skills/${slug}?file=${encodeURIComponent(path)}`
    return children.length > 0 ? (
      <MetaBranch
        key={path}
        branchKey={`skills:dir:${slug}:${path}`}
        label={name}
        icon={<RiFolderLine aria-hidden className="pod-page-icon" />}
        {...props}>
        <SkillFileTree slug={slug} paths={children} prefix={`${path}/`} {...props} />
      </MetaBranch>
    ) : (
      <MetaTreeItem
        key={path}
        to={to}
        pathname={props.pathname}
        searchStr={props.searchStr}
        activeSection={props.activeSection}
        onNavigate={props.onNavigate}>
        <RiFileTextLine aria-hidden className="pod-page-icon" />
        <span className="min-w-0 truncate text-left" dir="auto">
          {name}
        </span>
      </MetaTreeItem>
    )
  })
}

function AgentsTree({ pathname, searchStr, activeSection, onNavigate }: MetaTreeProps) {
  const { t } = useTranslation()
  const agents = useQuery(metaAgentsQuery())
  const colleagues = agents.data?.agents.filter(agent => agent.type === 'ai_colleague') ?? []
  return (
    <>
      {colleagues.map(agent => (
        <MetaTreeItem
          key={agent.uid}
          to={`/meta/agents/colleagues/${agent.uid}`}
          pathname={pathname}
          searchStr={searchStr}
          activeSection={activeSection}
          onNavigate={onNavigate}>
          <span className="pod-conversation-glyph" data-size="sm">
            <ChatAvatar name={agent.display_name} src={agent.avatar_url} agent />
          </span>
          <span className="min-w-0 truncate text-left" dir="auto">
            {agent.display_name}
          </span>
        </MetaTreeItem>
      ))}
      <MetaTreeItem
        className={colleagues.length > 0 ? 'mt-1 border-t border-border pt-1' : undefined}
        to="/meta/agents/assistant"
        pathname={pathname}
        searchStr={searchStr}
        activeSection={activeSection}
        onNavigate={onNavigate}>
        <RiSparklingLine aria-hidden className="pod-page-icon" />
        <span className="min-w-0 truncate text-left" dir="auto">
          {t('pod.meta.assistant')}
        </span>
      </MetaTreeItem>
      <MetaTreeItem
        to="/meta/agents/global"
        pathname={pathname}
        searchStr={searchStr}
        activeSection={activeSection}
        onNavigate={onNavigate}>
        <RiSettings3Line aria-hidden className="pod-page-icon" />
        <span className="min-w-0 truncate text-left" dir="auto">
          {t('pod.meta.global')}
        </span>
      </MetaTreeItem>
    </>
  )
}
