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
  metaSaveSkill,
  metaDeleteSkill,
  type MetaSkill
} from './meta-api'

export function MetaSkills() {
  const { t } = useTranslation()
  const skills = useQuery(metaSkillsQuery())
  const [creating, setCreating] = useState<'new' | 'import' | null>(null)
  const [search, setSearch] = useState('')
  const matches = skills.data?.skills.filter(skill =>
    `${skill.name} ${skill.slug} ${skill.description}`.toLocaleLowerCase().includes(search.toLocaleLowerCase())
  )
  return (
    <div className="mx-auto w-full max-w-5xl space-y-5 p-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">{t('pod.meta.skills')}</h1>
        {skills.data?.can_create && (
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setCreating(creating === 'import' ? null : 'import')}>
              {t('pod.meta.import_skill')}
            </Button>
            <Button onClick={() => setCreating(creating === 'new' ? null : 'new')}>{t('pod.meta.new_skill')}</Button>
          </div>
        )}
      </div>
      {creating && <CreateSkill key={creating} importing={creating === 'import'} />}
      <div>
        <label htmlFor="meta-skill-search" className="mb-1 block text-sm">
          {t('pod.meta.find_skill')}
        </label>
        <Input id="meta-skill-search" type="search" value={search} onChange={event => setSearch(event.target.value)} />
      </div>
      {skills.error && <ContentError error={skills.error} retry={() => void skills.refetch()} />}
      {matches?.length === 0 && <p className="text-sm text-fg-secondary">{t('pod.meta.no_skills')}</p>}
      {matches?.map(skill => (
        <SkillRow key={skill.id} skill={skill} />
      ))}
    </div>
  )
}
function CreateSkill({ importing }: { importing: boolean }) {
  useSignals()
  const { t } = useTranslation()
  const form = useSignal({ slug: '', name: '', description: '' })
  const file = useSignal<File | null>(null)
  const id = useId()
  const navigate = useNavigate()
  const client = useQueryClient()
  const create = useMutation({
    mutationFn: async () =>
      importing
        ? metaImportSkill({ body: { data: { slug: form.value.slug, content_base64: await fileBase64(file.value!) } } })
        : metaCreateSkill({
            body: {
              data: {
                slug: form.value.slug,
                manifest_xml: '<page><p /></page>',
                metadata: { name: form.value.name, description: form.value.description }
              }
            }
          }),
    onSuccess: async skill => {
      await client.invalidateQueries({ queryKey: metaKeys.skills() })
      void navigate({ to: `/meta/skills/${skill.slug}` })
    }
  })
  return (
    <form
      className="space-y-3 rounded-lg border border-border p-5"
      onSubmit={event => {
        event.preventDefault()
        create.mutate()
      }}>
      {(importing ? (['slug'] as const) : (['slug', 'name', 'description'] as const)).map(field => (
        <div key={field}>
          <label htmlFor={`${id}-${field}`} className="mb-1 block text-sm">
            {t(`pod.meta.${field}`)}
          </label>
          <Input
            id={`${id}-${field}`}
            value={form.value[field]}
            disabled={create.isPending}
            required
            autoCapitalize={field === 'slug' ? 'none' : undefined}
            spellCheck={field !== 'slug'}
            pattern={field === 'slug' ? '[a-z0-9][a-z0-9._\\-]{0,95}' : undefined}
            onChange={event => {
              form.value = { ...form.value, [field]: event.target.value }
            }}
          />
        </div>
      ))}
      {importing && (
        <>
          <label htmlFor={`${id}-zip`} className="block text-sm">
            {t('pod.meta.import_zip')}
          </label>
          <Input
            id={`${id}-zip`}
            type="file"
            accept=".zip"
            required
            disabled={create.isPending}
            onChange={event => {
              file.value = event.target.files?.[0] ?? null
            }}
          />
        </>
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
  return (
    <article className="rounded-lg border border-border p-4">
      <div className="flex items-center justify-between gap-4">
        <div className="min-w-0">
          <Link to={`/meta/skills/${skill.slug}`} className="font-semibold hover:underline">
            {skill.name}
          </Link>
          <p className="text-xs text-fg-tertiary">
            {skill.slug} · {t(`pod.meta.source_${skill.source_kind}`)}
          </p>
          <p className="mt-2 text-sm text-fg-secondary">{skill.description}</p>
          <p className="mt-1 text-xs text-fg-tertiary">
            {skill.enabled_for_all
              ? t('pod.meta.all_agents')
              : t('pod.meta.binding_summary', {
                  count: skill.colleague_count,
                  assistant: t(skill.assistant_enabled ? 'pod.meta.assistant_enabled' : 'pod.meta.assistant_disabled')
                })}
          </p>
        </div>
        <Button variant="ghost" size="sm" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
          {t('pod.meta.enablement')}
        </Button>
      </div>
      {expanded && <SkillBindings skill={skill} />}
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
  const refresh = () => client.invalidateQueries({ queryKey: metaKeys.skills() })
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
  return (
    <div className="mx-auto w-full max-w-5xl space-y-5 p-6">
      <div className="flex items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">{row.name}</h1>
        {row.can_delete && (
          <Button variant="outline" disabled={remove.isPending} onClick={() => setDeleting(true)}>
            {t('common.delete')}
          </Button>
        )}
      </div>
      {deleting && (
        <DeleteSkillDialog
          name={row.name}
          pending={remove.isPending}
          close={() => setDeleting(false)}
          confirm={() => remove.mutate()}
        />
      )}
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
      <SkillBindings skill={row} />
    </div>
  )
}
