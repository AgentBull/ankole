import { downloadBlob } from '../common/browser-files'
import { Button, Input, Switch, Textarea, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useModel, useSignal } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useSearchParams } from '../common/router'
import { ContentError, ContentSkeleton } from './content-primitives'
import { DraftNavigationGuard } from './draft-navigation-guard'
import { DocumentDraftModel } from './state/document-draft'
import {
  fileBase64,
  metaKeys,
  metaSkillQuery,
  metaSkillPutFile,
  metaSkillChangeFile,
  metaSkillFile,
  type MetaSkill
} from './meta-api'

async function downloadSkillFile(slug: string, path: string) {
  const result = await metaSkillFile({ path: { slug }, query: { path } })
  const blob = new Blob([Uint8Array.from(atob(result.content_base64), char => char.charCodeAt(0))])
  downloadBlob(blob, path.split('/').at(-1)!)
}

export function DeleteSkillDialog({
  name,
  pending,
  close,
  confirm
}: {
  name: string
  pending: boolean
  close(): void
  confirm(): void
}) {
  const { t } = useTranslation()
  return (
    <Dialog open onOpenChange={open => !open && !pending && close()}>
      <DialogContent closeLabel={t('common.close')} showCloseButton={!pending}>
        <DialogTitle>{t('pod.meta.delete_permanently')}</DialogTitle>
        <p>{t('pod.meta.delete_confirmation', { name })}</p>
        <DialogFooter>
          <Button variant="outline" disabled={pending} onClick={close}>
            {t('common.cancel')}
          </Button>
          <Button variant="destructive" disabled={pending} onClick={confirm}>
            {t('common.delete')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function SkillPackage({
  skill,
  files
}: {
  skill: MetaSkill
  files: NonNullable<Awaited<ReturnType<typeof import('./meta-api').metaSkill>>>['files']
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const path = useSignal('')
  const selected = useSignal<File | null>(null)
  const executable = useSignal(false)
  const [renaming, setRenaming] = useState<string | null>(null)
  const rename = useSignal('')
  const [deleting, setDeleting] = useState<string | null>(null)
  const [params, setParams] = useSearchParams()
  const mutation = useMutation({
    mutationFn: async (
      action:
        | { kind: 'upload' }
        | { kind: 'change'; path: string; new_path?: string }
        | { kind: 'download'; path: string }
    ) => {
      if (action.kind === 'download') {
        await downloadSkillFile(skill.slug, action.path)
      } else if (action.kind === 'upload') {
        const file = selected.value!
        await metaSkillPutFile({
          path: { slug: skill.slug },
          body: {
            data: {
              path: path.value || file.name,
              content_base64: await fileBase64(file),
              mode: executable.value ? 365 : 292,
              content_type: file.type || 'application/octet-stream',
              base_revision: skill.revision
            }
          }
        })
      } else {
        await metaSkillChangeFile({
          path: { slug: skill.slug },
          body: { data: { path: action.path, new_path: action.new_path, base_revision: skill.revision } }
        })
      }
    },
    onSuccess: async (_, action) => {
      if (action.kind === 'download') return
      setRenaming(null)
      setDeleting(null)
      await client.invalidateQueries({ queryKey: metaKeys.skills() })
      if (action.kind === 'upload') setParams({ file: path.value || selected.value!.name })
      else if (params.get('file') === action.path) setParams(action.new_path ? { file: action.new_path } : {})
    },
    onError: () => client.invalidateQueries({ queryKey: metaKeys.skills() })
  })
  return (
    <section className="space-y-4 rounded-lg border border-border p-5">
      <h2 className="font-semibold">{t('pod.meta.package_files')}</h2>
      <ul className="space-y-3">
        <li>
          <Link to={`/meta/skills/${skill.slug}`} search={{ file: 'SKILL.md' }} className="nav-row">
            SKILL.md
          </Link>
        </li>
        {files.map(file => (
          <li key={file.id} className="flex flex-wrap items-center gap-2">
            <Link
              to={`/meta/skills/${skill.slug}`}
              search={{ file: file.relative_path }}
              className="nav-row min-w-0 flex-1 break-all">
              {file.relative_path}
            </Link>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => mutation.mutate({ kind: 'download', path: file.relative_path })}>
              {t('common.download')}
            </Button>
            {skill.can_edit && (
              <>
                {renaming === file.id ? (
                  <>
                    <Input
                      className="w-56"
                      aria-label={t('pod.meta.rename_file', { path: file.relative_path })}
                      value={rename.value}
                      disabled={mutation.isPending}
                      autoFocus
                      onChange={event => {
                        rename.value = event.target.value
                      }}
                    />
                    <Button
                      size="sm"
                      disabled={mutation.isPending || !rename.value || rename.value === file.relative_path}
                      onClick={() =>
                        mutation.mutate({ kind: 'change', path: file.relative_path, new_path: rename.value })
                      }>
                      {t('common.save')}
                    </Button>
                    <Button size="sm" variant="ghost" disabled={mutation.isPending} onClick={() => setRenaming(null)}>
                      {t('common.cancel')}
                    </Button>
                  </>
                ) : (
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => {
                      rename.value = file.relative_path
                      setRenaming(file.id)
                    }}>
                    {t('pod.meta.rename')}
                  </Button>
                )}
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={mutation.isPending}
                  onClick={() => setDeleting(file.relative_path)}>
                  {t('common.delete')}
                </Button>
              </>
            )}
          </li>
        ))}
      </ul>
      {skill.can_edit && (
        <form
          className="space-y-3 border-t border-border pt-4"
          onSubmit={event => {
            event.preventDefault()
            mutation.mutate({ kind: 'upload' })
          }}>
          <label htmlFor="meta-package-file" className="block text-sm">
            {t('pod.meta.upload_file')}
          </label>
          <Input
            id="meta-package-file"
            type="file"
            required
            disabled={mutation.isPending}
            onChange={event => {
              selected.value = event.target.files?.[0] ?? null
            }}
          />
          <label htmlFor="meta-package-path" className="block text-sm">
            {t('pod.meta.file_path')}
          </label>
          <Input
            id="meta-package-path"
            value={path.value}
            disabled={mutation.isPending}
            placeholder={selected.value?.name}
            onChange={event => {
              path.value = event.target.value
            }}
          />
          <label className="flex items-center gap-3 text-sm">
            <Switch
              checked={executable.value}
              disabled={mutation.isPending}
              onCheckedChange={value => {
                executable.value = value
              }}
            />
            {t('pod.meta.executable')}
          </label>
          <Button type="submit" disabled={!selected.value || mutation.isPending}>
            {t('pod.meta.upload_replace')}
          </Button>
        </form>
      )}
      {deleting && (
        <DeleteSkillDialog
          name={deleting}
          pending={mutation.isPending}
          close={() => setDeleting(null)}
          confirm={() => mutation.mutate({ kind: 'change', path: deleting })}
        />
      )}
      {mutation.error && <ContentError error={mutation.error} />}
    </section>
  )
}

export function SelectedFile({ skill }: { skill: MetaSkill }) {
  const { t } = useTranslation()
  const [params] = useSearchParams()
  const path = params.get('file')!
  const query = useQuery({
    queryKey: [...metaKeys.skill(skill.slug), 'file', path],
    queryFn: ({ signal }) => metaSkillFile({ path: { slug: skill.slug }, query: { path }, signal })
  })
  const download = useMutation({ mutationFn: () => downloadSkillFile(skill.slug, path) })
  const text = useMemo(() => {
    if (!query.data) return null
    try {
      const bytes = Uint8Array.from(atob(query.data.content_base64), char => char.charCodeAt(0))
      const value = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
      return value.includes('\0') ? null : value
    } catch {
      return null
    }
  }, [query.data])
  return (
    <section className="space-y-3 rounded-lg border border-border p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 className="break-all font-semibold">{path}</h2>
        <div className="flex items-center gap-3">
          <Link to={`/meta/skills/${skill.slug}`} search={{ file: 'SKILL.md' }} className="text-sm hover:underline">
            SKILL.md
          </Link>
          <Button variant="outline" size="sm" disabled={download.isPending} onClick={() => download.mutate()}>
            {t('common.download')}
          </Button>
        </div>
      </div>
      {query.error && <ContentError error={query.error} retry={() => void query.refetch()} />}
      {download.error && <ContentError error={download.error} />}
      {query.isPending && <ContentSkeleton variant="text" />}
      {query.data &&
        (text === null ? (
          <p className="text-sm text-fg-secondary">{t('pod.meta.binary_file')}</p>
        ) : (
          <TextFile
            key={`${skill.slug}:${path}`}
            path={path}
            source={text}
            revision={query.data.revision}
            skill={skill}
          />
        ))}
    </section>
  )
}
function TextFile({
  path,
  source,
  revision,
  skill
}: {
  path: string
  source: string
  revision: number
  skill: MetaSkill
}) {
  useSignals()
  const { t } = useTranslation()
  const draft = useModel(DocumentDraftModel)
  const client = useQueryClient()
  const detail = useQuery(metaSkillQuery(skill.slug))
  const file = detail.data?.files.find(file => file.relative_path === path)
  const [reviewing, setReviewing] = useState(false)
  useEffect(() => {
    draft.load(path, source, revision)
    if (revision >= draft.revision.peek() && (!draft.dirty.peek() || source === draft.savedXML.peek())) {
      if (!draft.dirty.peek()) draft.xml.value = source
      draft.saved(source, revision, false)
    }
  }, [draft, path, source, revision])
  const save = useMutation({
    mutationFn: async () => {
      const submitted = draft.xml.value
      const result = await metaSkillPutFile({
        path: { slug: skill.slug },
        body: {
          data: {
            path,
            content_base64: await fileBase64(new File([submitted], path)),
            base_revision: draft.revision.value,
            mode: file?.mode ?? 292,
            content_type: file?.content_type ?? 'text/plain'
          }
        }
      })
      return { submitted, revision: result.revision }
    },
    onSuccess: result => {
      draft.saved(result.submitted, result.revision, false)
      setReviewing(false)
    },
    onSettled: () => client.invalidateQueries({ queryKey: metaKeys.skills() })
  })
  return (
    <div className="space-y-3">
      <DraftNavigationGuard dirty={draft.hasUnsavedChanges.value} />
      <Textarea
        aria-label={path}
        className="min-h-72 font-mono text-sm"
        value={draft.xml.value}
        readOnly={!skill.can_edit || save.isPending}
        onChange={event => {
          draft.xml.value = event.target.value
          save.reset()
        }}
      />
      {skill.can_edit && (
        <Button disabled={save.isPending || !draft.dirty.value} onClick={() => save.mutate()}>
          {t('common.save')}
        </Button>
      )}
      {save.isSuccess && (
        <p role="status" className="text-sm text-fg-secondary">
          {t('pod.meta.saved')}
        </p>
      )}
      {save.error && <ContentError error={save.error} />}
      {(reviewing || (save.isError && draft.revision.value !== revision)) && (
        <div className="space-y-3">
          <p className="text-sm text-fg-secondary">{t('pod.meta.draft_conflict')}</p>
          <details open={reviewing}>
            <summary>{t('pod.knowledge.latest_revision')}</summary>
            <pre className="whitespace-pre-wrap">{source}</pre>
          </details>
          <Button
            variant="outline"
            onClick={() => {
              draft.saved(source, revision, false)
              setReviewing(true)
              save.reset()
            }}>
            {t('pod.knowledge.load_latest')}
          </Button>
          <Button
            variant="ghost"
            onClick={() => {
              draft.xml.value = source
              draft.saved(source, revision, false)
              setReviewing(false)
              save.reset()
            }}>
            {t('pod.meta.load_latest')}
          </Button>
        </div>
      )}
    </div>
  )
}
