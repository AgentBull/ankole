import { Button, Input } from '@ankole/uikit'
import { useSignal } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from '../common/router'
import { ContentError, ContentSkeleton } from './content-primitives'
import { SkillPackage, SelectedFile, DeleteSkillDialog } from './meta-skill-files'
import { MetaDocument } from './meta-document'
import { SkillBindings } from './meta-skill-bindings'
export { SkillBindings } from './meta-skill-bindings'
import {
  fileBase64,
  metaKeys,
  metaSkillsQuery,
  metaSkillQuery,
  metaCreateSkill,
  metaImportSkill,
  metaPublishSkill,
  metaSaveSkill,
  metaDeleteSkill,
  type MetaSkill
} from './meta-api'

type SkillScopeFilter = 'all' | 'personal' | 'workspace' | 'builtin'

export function MetaSkills() {
  const { t } = useTranslation()
  const skills = useQuery(metaSkillsQuery())
  const [creating, setCreating] = useState<'new' | 'import' | null>(null)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<SkillScopeFilter>('all')
  const matches = skills.data?.skills.filter(skill => {
    const matchesSearch = `${skill.name} ${skill.slug} ${skill.description}`
      .toLocaleLowerCase()
      .includes(search.toLocaleLowerCase())
    if (!matchesSearch) return false
    if (filter === 'personal') return Boolean(skill.agent_uid)
    if (filter === 'workspace') return !skill.agent_uid && skill.source_kind === 'custom'
    if (filter === 'builtin') return skill.source_kind !== 'custom'
    return true
  })
  return (
    <div className="mx-auto w-full max-w-5xl space-y-5 p-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">{t('pod.meta.skills')}</h1>
        {skills.data?.can_create && (
          <div className="flex gap-2">
            <Button
              type="button"
              variant="outline"
              onClick={() => setCreating(creating === 'import' ? null : 'import')}>
              {t('pod.meta.import_skill')}
            </Button>
            <Button type="button" onClick={() => setCreating(creating === 'new' ? null : 'new')}>
              {t('pod.meta.new_skill')}
            </Button>
          </div>
        )}
      </div>
      {creating && (
        <CreateSkill
          key={creating}
          importing={creating === 'import'}
          canCreateWorkspace={Boolean(skills.data?.can_create_workspace)}
        />
      )}
      <search className="space-y-3">
        <div>
          <label htmlFor="meta-skill-search" className="mb-1 block text-sm">
            {t('pod.meta.find_skill')}
          </label>
          <Input
            id="meta-skill-search"
            type="search"
            autoCorrect="off"
            autoCapitalize="none"
            spellCheck={false}
            value={search}
            onChange={event => setSearch(event.target.value)}
          />
        </div>
        <div
          className="flex flex-wrap items-center gap-1.5"
          role="group"
          aria-label={t('pod.meta.filter_skills_label', { defaultValue: 'Skill visibility filter' })}>
          {(['all', 'personal', 'workspace', 'builtin'] as const).map(option => (
            <Button
              key={option}
              type="button"
              size="xs"
              variant={filter === option ? 'outline' : 'ghost'}
              aria-pressed={filter === option}
              onClick={() => setFilter(option)}>
              {t(`pod.meta.filter_${option}`, {
                defaultValue:
                  option === 'all'
                    ? 'All'
                    : option === 'personal'
                      ? 'My Personal'
                      : option === 'workspace'
                        ? 'Workspace'
                        : 'Built-in'
              })}
            </Button>
          ))}
        </div>
      </search>
      {skills.isPending && <ContentSkeleton variant="list" rows={6} />}
      {skills.error && <ContentError error={skills.error} retry={() => void skills.refetch()} />}
      {matches?.length === 0 && <p className="text-sm text-fg-secondary">{t('pod.meta.no_skills')}</p>}
      {matches?.map(skill => (
        <SkillRow key={skill.id} skill={skill} />
      ))}
    </div>
  )
}
function CreateSkill({ importing, canCreateWorkspace }: { importing: boolean; canCreateWorkspace: boolean }) {
  useSignals()
  const { t } = useTranslation()
  const form = useSignal({ slug: '', name: '', description: '' })
  const scope = useSignal<'personal' | 'workspace'>('personal')
  const file = useSignal<File | null>(null)
  const id = useId()
  const navigate = useNavigate()
  const client = useQueryClient()
  const create = useMutation({
    mutationFn: async () => {
      const personal = scope.value === 'personal' || !canCreateWorkspace
      return importing
        ? metaImportSkill({
            body: {
              data: {
                slug: form.value.slug.trim(),
                personal,
                content_base64: await fileBase64(file.value!)
              }
            }
          })
        : metaCreateSkill({
            body: {
              data: {
                slug: form.value.slug.trim(),
                personal,
                manifest_xml: '<page><p /></page>',
                metadata: { name: form.value.name, description: form.value.description }
              }
            }
          })
    },
    onSuccess: async skill => {
      await Promise.all([
        client.invalidateQueries({ queryKey: metaKeys.skills() }),
        client.invalidateQueries({ queryKey: metaKeys.agents() })
      ])
      void navigate({ to: `/meta/skills/${skill.slug}` })
    }
  })
  return (
    <form
      className="space-y-4 rounded-lg border border-border p-5"
      onSubmit={event => {
        event.preventDefault()
        create.mutate()
      }}>
      <fieldset className="space-y-2">
        <legend className="mb-1 text-sm font-medium">
          {t('pod.meta.skill_scope_label', { defaultValue: 'Ownership & visibility' })}
        </legend>
        <div className="flex flex-wrap gap-4 text-sm">
          <div className="flex items-center gap-2">
            <input
              id={`${id}-scope-personal`}
              type="radio"
              name={`${id}-scope`}
              value="personal"
              checked={scope.value === 'personal' || !canCreateWorkspace}
              disabled={create.isPending}
              onChange={() => {
                scope.value = 'personal'
              }}
            />
            <label htmlFor={`${id}-scope-personal`}>
              {t('pod.meta.scope_personal_option', { defaultValue: 'Personal (only my Personal Assistant)' })}
            </label>
          </div>
          <div className="flex items-center gap-2">
            <input
              id={`${id}-scope-workspace`}
              type="radio"
              name={`${id}-scope`}
              value="workspace"
              checked={canCreateWorkspace && scope.value === 'workspace'}
              disabled={!canCreateWorkspace || create.isPending}
              onChange={() => {
                scope.value = 'workspace'
              }}
            />
            <label htmlFor={`${id}-scope-workspace`} className={!canCreateWorkspace ? 'text-fg-tertiary' : undefined}>
              {t('pod.meta.scope_workspace_option', { defaultValue: 'Workspace (shared for AI Colleagues & team)' })}
            </label>
          </div>
        </div>
      </fieldset>
      {!importing &&
        (['name', 'description'] as const).map(field => (
          <div key={field}>
            <label htmlFor={`${id}-${field}`} className="mb-1 block text-sm">
              {t(`pod.meta.${field}`)}
            </label>
            <Input
              id={`${id}-${field}`}
              name={field}
              value={form.value[field]}
              disabled={create.isPending}
              required
              onChange={event => {
                form.value = { ...form.value, [field]: event.target.value }
              }}
            />
          </div>
        ))}
      <div>
        <label htmlFor={`${id}-slug`} className="mb-1 block text-sm">
          {t('pod.meta.slug_optional', { defaultValue: 'Slug (optional, auto-generated from name when blank)' })}
        </label>
        <Input
          id={`${id}-slug`}
          name="slug"
          value={form.value.slug}
          disabled={create.isPending}
          autoCorrect="off"
          autoCapitalize="none"
          spellCheck={false}
          pattern="[a-z0-9][a-z0-9._\-]{0,95}"
          onChange={event => {
            form.value = { ...form.value, slug: event.target.value }
          }}
        />
      </div>
      {importing && (
        <div>
          <label htmlFor={`${id}-zip`} className="mb-1 block text-sm">
            {t('pod.meta.import_zip')}
          </label>
          <Input
            id={`${id}-zip`}
            name="archive"
            type="file"
            accept=".zip"
            required
            disabled={create.isPending}
            onChange={event => {
              file.value = event.target.files?.[0] ?? null
            }}
          />
        </div>
      )}
      <Button type="submit" disabled={create.isPending}>
        {t('pod.meta.create')}
      </Button>
      {create.error && <ContentError error={create.error} />}
    </form>
  )
}
function SkillRow({ skill }: { skill: MetaSkill }) {
  const { t } = useTranslation()
  const [expanded, setExpanded] = useState(false)
  const isPersonal = Boolean(skill.agent_uid)
  return (
    <article className="rounded-lg border border-border p-4">
      <div className="flex items-center justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <Link to={`/meta/skills/${skill.slug}`} className="font-semibold hover:underline">
              {skill.name}
            </Link>
            <code className="rounded-mini bg-muted px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
              /{skill.slug}
            </code>
            {isPersonal ? (
              <span className="rounded-mini bg-primary/10 px-1.5 py-0.5 text-xs font-medium text-primary">
                {t('pod.meta.scope_personal_badge', { defaultValue: 'Personal' })}
              </span>
            ) : (
              <span className="text-xs text-fg-tertiary">{t(`pod.meta.source_${skill.source_kind}`)}</span>
            )}
          </div>
          <p className="mt-2 text-sm text-fg-secondary">{skill.description}</p>
          <p className="mt-1 text-xs text-fg-tertiary">
            {isPersonal
              ? t('pod.meta.personal_skill_summary', {
                  defaultValue: 'Private to you · Always enabled on your Personal Assistant'
                })
              : skill.enabled_for_all
                ? t('pod.meta.all_agents')
                : t('pod.meta.binding_summary', {
                    count: skill.colleague_count,
                    assistant: t(skill.assistant_enabled ? 'pod.meta.assistant_enabled' : 'pod.meta.assistant_disabled')
                  })}
          </p>
        </div>
        {!isPersonal && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            aria-expanded={expanded}
            onClick={() => setExpanded(!expanded)}>
            {t('pod.meta.enablement')}
          </Button>
        )}
      </div>
      {!isPersonal && expanded && <SkillBindings skill={skill} />}
    </article>
  )
}
export function MetaSkillDetail() {
  const slug = useParams({ strict: false }).skillSlug ?? ''
  return <SkillDetail key={slug} slug={slug} />
}

function SkillDetail({ slug }: { slug: string }) {
  useSignals()
  const { t } = useTranslation()
  const skill = useQuery(metaSkillQuery(slug))
  const client = useQueryClient()
  const navigate = useNavigate()
  const newSlug = useSignal('')
  const [deleting, setDeleting] = useState(false)
  const [params] = useSearchParams()
  const selectedPath = params.get('file')
  const refresh = () =>
    Promise.all([
      client.invalidateQueries({ queryKey: metaKeys.skills() }),
      client.invalidateQueries({ queryKey: metaKeys.agents() })
    ])
  const publish = useMutation({
    mutationFn: () =>
      metaPublishSkill({
        path: { slug },
        body: { data: { base_revision: skill.data!.skill.revision } }
      }),
    onSuccess: async () => {
      await refresh()
    }
  })
  const remove = useMutation({
    mutationFn: () => metaDeleteSkill({ path: { slug }, query: { base_revision: skill.data!.skill.revision } }),
    onSuccess: async () => {
      await refresh()
      void navigate({ to: '/meta/skills' })
    }
  })
  if (skill.error) return <ContentError error={skill.error} retry={() => void skill.refetch()} />
  if (!skill.data) return <ContentSkeleton variant="page" />
  const row = skill.data.skill
  const isPersonal = Boolean(row.agent_uid)
  const deleteImpactNotice = isPersonal
    ? undefined
    : row.enabled_for_all
      ? t('pod.meta.delete_impact_all_agents', {
          defaultValue: 'This Skill is currently enabled for all Agents across the workspace.'
        })
      : row.colleague_count > 0 || row.assistant_enabled
        ? t('pod.meta.delete_impact_bound_agents', {
            defaultValue: 'This Skill is currently bound to {$count} Agent(s); deleting it removes those bindings.',
            count: row.colleague_count + (row.assistant_enabled ? 1 : 0)
          })
        : undefined
  return (
    <div className="mx-auto w-full max-w-5xl space-y-5 p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2.5">
          <h1 className="text-2xl font-semibold">{row.name}</h1>
          <code className="rounded-mini bg-muted px-2 py-0.5 font-mono text-xs text-fg-secondary">/{row.slug}</code>
          {isPersonal && (
            <span className="rounded-mini bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
              {t('pod.meta.scope_personal_badge', { defaultValue: 'Personal' })}
            </span>
          )}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {row.can_publish && (
            <Button type="button" variant="outline" disabled={publish.isPending} onClick={() => publish.mutate()}>
              {t('pod.meta.publish_to_workspace', { defaultValue: 'Publish to workspace' })}
            </Button>
          )}
          {row.can_delete && (
            <Button type="button" variant="outline" disabled={remove.isPending} onClick={() => setDeleting(true)}>
              {t('common.delete')}
            </Button>
          )}
        </div>
      </div>
      {deleting && (
        <DeleteSkillDialog
          name={row.name}
          impactNotice={deleteImpactNotice}
          pending={remove.isPending}
          close={() => setDeleting(false)}
          confirm={() => remove.mutate()}
        />
      )}
      {publish.error && <ContentError error={publish.error} />}
      {remove.error && <ContentError error={remove.error} />}
      {selectedPath && selectedPath !== 'SKILL.md' ? (
        <SelectedFile skill={row} />
      ) : (
        <MetaDocument
          key={`manifest:${row.id}`}
          title="SKILL.md"
          xml={row.manifest_xml}
          metadata={row.metadata}
          revision={row.revision}
          canEdit={row.can_edit}
          pendingChanges={!!newSlug.value && newSlug.value !== slug}
          onBegin={() => {
            newSlug.value = ''
          }}
          save={async value => {
            let result
            try {
              result = await metaSaveSkill({
                path: { slug },
                body: {
                  data: {
                    manifest_xml: value.xml,
                    metadata: value.metadata,
                    base_revision: value.base_revision,
                    ...(newSlug.value ? { new_slug: newSlug.value } : {})
                  }
                }
              })
            } catch (error) {
              await refresh()
              throw error
            }
            await client.invalidateQueries({
              queryKey: metaKeys.skills(),
              refetchType: result.slug === slug ? 'active' : 'none'
            })
            return result
          }}
          onSaved={result => {
            if (result.slug !== slug) void navigate({ to: `/meta/skills/${result.slug}`, ignoreBlocker: true })
          }}>
          {editing =>
            row.can_edit &&
            row.source_kind === 'custom' && (
              <div>
                <label htmlFor="meta-skill-slug" className="mb-1 block text-sm">
                  {t('pod.meta.slug')}
                </label>
                <Input
                  id="meta-skill-slug"
                  disabled={!editing}
                  placeholder={row.slug}
                  autoCorrect="off"
                  autoCapitalize="none"
                  spellCheck={false}
                  value={newSlug.value}
                  onChange={event => {
                    newSlug.value = event.target.value
                  }}
                />
              </div>
            )
          }
        </MetaDocument>
      )}
      <SkillPackage key={`package:${row.id}`} skill={row} files={skill.data.files} />
      {!isPersonal && <SkillBindings skill={row} />}
    </div>
  )
}
