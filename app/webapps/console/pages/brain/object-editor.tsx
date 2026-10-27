import {
  Badge,
  Button,
  Input,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Textarea,
  buttonVariants,
  cn,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useNavigate, useParams } from '@tanstack/react-router'
import { listBrainObjectTypesOptions, showBrainObjectOptions } from '../../api/v2/generated/@tanstack/react-query.gen'
import { createBrainObjectMutation, updateBrainObjectMutation } from '../../api/v2/generated/@tanstack/react-query.gen'
import type { BrainObjectPage } from '../../state/brain-object-editor-model'
import { requestErrorCode, requestErrorDetails } from '../../../common/request-errors'
import { ErrorBlock } from '../../../common/error-block'
import { EditorNotFound, LabeledField, ReadOnlyValue, ResourceEditorPage } from '../../console-form'
import { JSONObjectField } from '../../json-object-field'
import { BackLink, PageStack } from '../../console-page'
import { MarkdownBody } from '../../../common/markdown-body'
import {
  BrainObjectEditorModel,
  brainObjectSnapshot,
  emptyBrainObjectSnapshot,
  previewBrainObjectBody,
  type BrainObjectDraftError
} from '../../state/brain-object-editor-model'
import { brainObjectPath } from './brain-nav'
import { useEditorDraft } from '../../use-editor-draft'

const MARKDOC_ERROR_CODES = new Set([
  'nested_audience_tag',
  'unopened_audience_tag',
  'unclosed_audience_tag',
  'misplaced_audience_tag'
])

type Translate = (key: string, values?: Record<string, unknown>) => string

export function BrainObjectEditorPage() {
  const slug = useParams({ strict: false }).slug ?? ''
  return <BrainObjectEditor key={slug} slug={slug} />
}

function BrainObjectEditor({ slug }: { slug: string }) {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const model = useModel(BrainObjectEditorModel)
  const [latest, setLatest] = useState<BrainObjectPage>()
  const active = useRef(false)
  const mode = slug ? 'edit' : 'new'

  const detail = useQuery({
    ...showBrainObjectOptions({ query: { slug } }),
    enabled: mode === 'edit' && Boolean(slug),
    refetchOnMount: 'always'
  })
  const page = detail.data?.object
  const types = useQuery({ ...listBrainObjectTypesOptions(), enabled: mode === 'new' })
  const typeNames = types.data?.types ?? []
  const brainObjectDraft = useMemo(
    () => (mode === 'new' ? emptyBrainObjectSnapshot() : page ? brainObjectSnapshot(page) : undefined),
    [mode, page]
  )
  const draftStatus = useEditorDraft(model, {
    sourceKey: slug ? `object:${slug}` : 'new',
    source: brainObjectDraft,
    absent: () => mode === 'edit' && requestErrorCode(detail.error) === 'not_found'
  })

  useEffect(() => {
    active.current = true
    return () => {
      active.current = false
      model.reset()
    }
  }, [model])

  const create = useMutation(createBrainObjectMutation())
  const update = useMutation(updateBrainObjectMutation())

  const writeError = mode === 'new' ? create.error : update.error
  const errorCode = requestErrorCode(writeError)
  const diagnostic = markdocDiagnostic(writeError, model.body.value)
  const conflict = errorCode === 'content_hash_conflict'
  const pending = create.isPending || update.isPending
  const readOnly = mode === 'edit' && page?.editable === false

  const submit = () => {
    model.validationError.value = undefined
    const draftError = model.draftError(mode)
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    if (mode === 'new') {
      create.mutate(
        { body: { data: model.createBody() } },
        {
          onSuccess: response => {
            toast.success(t('console.brain.object_created', { slug: response.slug }))
            void navigate({ to: brainObjectPath(response.slug) })
          }
        }
      )
    } else if (page?.editable && model.contentHash.value) {
      update.mutate(
        { body: { data: model.updateBody() } },
        {
          // The write gives the object summary; the editor takes the new
          // content hash and the normalized tags from the page.
          onSuccess: async response => {
            const saved = await detail.refetch()
            if (!active.current || !saved.isSuccess || !saved.data?.object) return
            model.markSaved(saved.data.object)
            setLatest(undefined)
            toast.success(t('console.brain.object_saved', { slug: response.slug }))
          }
        }
      )
    }
  }

  const loadLatest = async () => {
    const result = await detail.refetch()
    if (active.current && result.isSuccess && result.data?.object) {
      setLatest(result.data.object)
      model.useLatestContentHash(result.data.object.content_hash ?? null)
    }
  }

  if (mode === 'edit' && draftStatus === 'loading' && !detail.error) {
    return (
      <PageStack className="mx-auto w-full max-w-6xl">
        <BackLink to="/brain/objects" />
        <Skeleton className="h-12 w-72" />
        <Skeleton className="h-[36rem] w-full" />
      </PageStack>
    )
  }

  if (draftStatus === 'absent') {
    return <EditorNotFound backTo="/brain/objects" message={t('console.not_found.description')} />
  }

  if (mode === 'edit' && detail.error && !page) {
    return (
      <PageStack className="mx-auto w-full max-w-6xl">
        <BackLink to="/brain/objects" />
        <ErrorBlock error={detail.error} />
      </PageStack>
    )
  }

  const validationError = model.validationError.value
    ? draftErrorText(model.validationError.value, t)
    : writeErrorText(writeError, t)
  const editorError = validationError || diagnostic || conflict ? undefined : writeError || detail.error
  const title = mode === 'new' ? t('console.brain.object_create_title') : t('console.brain.object_edit_title')
  const description = readOnly
    ? editBlockText(page?.edit_block_reason, t)
    : t('console.brain.object_editor_description')
  const fields = (
    <>
      <LabeledField
        label={t('console.brain.object_title')}
        required
        error={model.validationError.value === 'title_required' ? draftErrorText('title_required', t) : undefined}
        invalidError={draftErrorText('title_required', t)}>
        <Input
          disabled={pending}
          pattern=".*\S.*"
          value={model.title.value}
          onChange={event => model.setTitle(event.target.value, mode === 'new')}
        />
      </LabeledField>

      <div className="grid gap-5 sm:grid-cols-2">
        <LabeledField
          label={t('console.brain.slug')}
          description={mode === 'new' ? t('console.brain.slug_hint') : undefined}
          required={mode === 'new'}
          error={model.validationError.value === 'slug_required' ? draftErrorText('slug_required', t) : undefined}
          invalidError={draftErrorText('slug_required', t)}>
          {mode === 'new' ? (
            <Input
              className="font-mono text-xs"
              disabled={pending}
              pattern=".*\S.*"
              spellCheck={false}
              value={model.slug.value}
              onChange={event => model.setSlug(event.target.value)}
            />
          ) : (
            <ReadOnlyValue mono>{model.slug.value}</ReadOnlyValue>
          )}
        </LabeledField>
        <LabeledField
          label={t('console.brain.type')}
          required={mode === 'new'}
          error={model.validationError.value === 'type_required' ? draftErrorText('type_required', t) : undefined}>
          {mode === 'new' ? (
            <Select
              disabled={pending}
              value={model.type.value || null}
              onValueChange={value => {
                model.type.value = String(value)
                if (model.validationError.value === 'type_required') model.validationError.value = undefined
              }}>
              <SelectTrigger className="w-full font-mono text-xs">
                <SelectValue placeholder={t('console.brain.type_placeholder')} />
              </SelectTrigger>
              <SelectContent emptyLabel={types.isLoading ? t('common.loading') : t('common.select_empty')}>
                {typeNames.map(name => (
                  <SelectItem key={name} value={name}>
                    {name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          ) : (
            <ReadOnlyValue mono>{model.type.value}</ReadOnlyValue>
          )}
        </LabeledField>
        <LabeledField label={t('console.brain.subtype')}>
          <Input
            className="font-mono text-xs"
            disabled={pending}
            spellCheck={false}
            value={model.subtype.value}
            onChange={event => (model.subtype.value = event.target.value)}
          />
        </LabeledField>
        <LabeledField label={t('console.brain.effective_date')}>
          <Input
            disabled={pending}
            type="date"
            value={model.effectiveDate.value}
            onChange={event => (model.effectiveDate.value = event.target.value)}
          />
        </LabeledField>
      </div>

      <LabeledField label={t('console.brain.tags')} description={t('console.brain.tags_hint')}>
        <div className="grid gap-2">
          {model.tags.value.map((tag, index) => (
            <div key={index} className="flex items-start gap-2">
              <Textarea
                aria-label={t('console.brain.tag_number', { number: index + 1 })}
                className="min-h-9 resize-y font-mono text-xs"
                disabled={pending}
                rows={Math.min(4, tag.split('\n').length)}
                spellCheck={false}
                value={tag}
                onChange={event => model.updateTag(index, event.target.value)}
              />
              <Button
                disabled={pending}
                size="sm"
                type="button"
                variant="outline"
                onClick={() => model.removeTag(index)}>
                {t('console.brain.tags_remove')}
              </Button>
            </div>
          ))}
          <Button
            className="justify-self-start"
            disabled={pending}
            size="sm"
            type="button"
            variant="outline"
            onClick={() => model.addTag()}>
            {t('console.brain.tags_add')}
          </Button>
        </div>
      </LabeledField>

      {readOnly ? (
        <LabeledField label={t('console.brain.meta')} description={t('console.brain.meta_hint')}>
          <ReadOnlyValue mono>{model.metaText.value}</ReadOnlyValue>
        </LabeledField>
      ) : (
        <JSONObjectField
          error={model.validationError.value === 'meta_invalid' ? draftErrorText('meta_invalid', t) : undefined}
          label={t('console.brain.meta')}
          name="meta"
          value={model.metaText.value}
          onChange={value => {
            model.metaText.value = value
            if (model.validationError.value === 'meta_invalid') model.validationError.value = undefined
          }}
        />
      )}

      <div className="grid min-w-0 gap-5 lg:grid-cols-2">
        <LabeledField label={t('console.brain.body_source')} description={t('console.brain.body_source_hint')}>
          <Textarea
            className="min-h-[32rem] resize-y font-mono text-xs leading-6"
            disabled={pending}
            spellCheck={false}
            value={model.body.value}
            onChange={event => (model.body.value = event.target.value)}
          />
        </LabeledField>

        <section className="grid min-w-0 content-start gap-3" aria-label={t('console.brain.preview')}>
          <div className="grid gap-1">
            <h3 className="text-sm font-medium">{t('console.brain.preview')}</h3>
            <p className="text-xs leading-5 text-muted-foreground">{t('console.brain.preview_hint')}</p>
          </div>
          <div className="grid min-h-[32rem] content-start gap-3 overflow-auto border border-border bg-background p-4">
            {model.previewError.value ? (
              <p role="alert" className="text-sm text-destructive-foreground">
                {t('console.brain.problem_at_line', model.previewError.value)}
              </p>
            ) : model.preview.value.length ? (
              model.preview.value.map((segment, index) => (
                <section
                  key={`${segment.scope}-${index}`}
                  className="grid gap-2 border-b border-border pb-3 last:border-0">
                  <div>
                    <Badge variant={segment.scope === 'world' ? 'secondary' : 'outline'}>{segment.scope}</Badge>
                  </div>
                  <MarkdownBody text={segment.text} />
                </section>
              ))
            ) : (
              <p className="text-sm text-muted-foreground">{t('console.brain.preview_empty')}</p>
            )}
          </div>
        </section>
      </div>

      <Problems diagnostic={diagnostic} />
      {conflict ? (
        <section
          className="grid gap-3 border border-warning/40 bg-warning-subtle p-4"
          aria-label={t('console.brain.conflict')}>
          <div className="grid gap-1">
            <h3 className="text-sm font-medium">{t('console.brain.conflict')}</h3>
            <p className="text-xs leading-5 text-muted-foreground">{t('console.brain.conflict_hint')}</p>
          </div>
          <div>
            <Button size="xs" type="button" variant="outline" onClick={() => void loadLatest()}>
              {t('console.brain.load_latest_for_comparison')}
            </Button>
          </div>
          {latest ? (
            <div className="grid gap-2">
              <p className="font-mono text-xs text-muted-foreground">{latest.content_hash}</p>
              <pre className="max-h-80 overflow-auto whitespace-pre-wrap border border-border bg-background p-3 font-mono text-xs leading-5">
                {latest.body}
              </pre>
            </div>
          ) : null}
        </section>
      ) : null}
    </>
  )

  const secondary = editBlockAction(page ?? undefined, t)
  const editor = readOnly ? (
    <ResourceEditorPage
      backTo={brainObjectPath(slug)}
      contentWidth="wide"
      description={description}
      error={editorError}
      readOnly
      secondary={secondary}
      title={title}>
      {fields}
    </ResourceEditorPage>
  ) : (
    <ResourceEditorPage
      backTo={mode === 'new' ? '/brain/objects' : brainObjectPath(slug)}
      contentWidth="wide"
      description={description}
      dirty={model.dirty.value}
      error={editorError}
      validationError={validationError}
      onSubmit={submit}
      submitDisabled={!model.dirty.value}
      submitUnavailable={draftStatus !== 'ready' || (mode === 'edit' && !model.contentHash.value)}
      submitting={pending}
      title={title}>
      {fields}
    </ResourceEditorPage>
  )

  return editor
}

function Problems({ diagnostic }: { diagnostic?: { code: string; line?: number } }) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-2 border border-border bg-background p-4" aria-label={t('console.brain.problems')}>
      <h3 className="text-sm font-medium">{t('console.brain.problems')}</h3>
      {diagnostic ? (
        <p className="font-mono text-xs text-destructive-foreground">
          {diagnostic.line
            ? t('console.brain.problem_at_line', { code: diagnostic.code, line: diagnostic.line })
            : diagnostic.code}
        </p>
      ) : (
        <p className="text-xs text-muted-foreground">{t('console.brain.no_problems')}</p>
      )}
    </section>
  )
}

/** The server gives the Markdoc code; the local preview of the sent body gives its line. */
function markdocDiagnostic(error: unknown, body: string): { code: string; line?: number } | undefined {
  const code = requestErrorCode(error)
  if (!code || !MARKDOC_ERROR_CODES.has(code)) return undefined
  const line = previewBrainObjectBody(body).error?.line
  return { code, ...(typeof line === 'number' ? { line } : {}) }
}

function draftErrorText(error: BrainObjectDraftError, t: Translate): string {
  switch (error) {
    case 'slug_required':
      return t('common.field_required', { field: t('console.brain.slug') })
    case 'type_required':
      return t('common.field_required', { field: t('console.brain.type') })
    case 'title_required':
      return t('common.field_required', { field: t('console.brain.object_title') })
    case 'meta_invalid':
      return t('console.brain.meta_invalid')
  }
}

const WRITE_FIELD_LABEL_KEYS: Record<string, string> = {
  slug: 'console.brain.slug',
  type: 'console.brain.type',
  title: 'console.brain.object_title',
  meta: 'console.brain.meta'
}

/** Localizes the coded object-write rejections; other errors render raw. */
function writeErrorText(error: unknown, t: Translate): string | undefined {
  const code = requestErrorCode(error)
  switch (code) {
    case 'validation_failed': {
      const details = requestErrorDetails(error)
      const labelKey = typeof details.path === 'string' ? WRITE_FIELD_LABEL_KEYS[details.path] : undefined
      if (!labelKey) return undefined
      const messageKey = details.kind === 'missing' ? 'common.field_required' : 'common.field_invalid'
      return t(messageKey, { field: t(labelKey) })
    }
    case 'invalid_slug':
      return t('console.brain.slug_invalid')
    case 'reserved_object_slug':
      return t('console.brain.slug_reserved')
    case 'slug_taken':
      return t('console.brain.slug_taken')
    case 'unknown_object_type':
      return t('console.brain.type_unknown')
    case 'reserved_object_type':
      return t('console.brain.type_reserved')
    case 'object_deleted':
      return t('console.brain.edit_block_deleted')
    default:
      return undefined
  }
}

function editBlockText(reason: string | null | undefined, t: Translate): string {
  switch (reason) {
    case 'deleted':
      return t('console.brain.edit_block_deleted')
    case 'library_managed':
      return t('console.brain.library_managed_hint')
    case 'source_managed':
      return t('console.brain.source_managed_hint')
    case 'agent_skills_managed':
      return t('console.brain.library_skill_managed_hint')
    default:
      return t('console.brain.object_editor_description')
  }
}

function editBlockAction(page: BrainObjectPage | undefined, t: Translate) {
  switch (page?.edit_block_reason) {
    case 'source_managed':
      return (
        <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to="/brain/sources">
          {t('console.brain.open_sources')}
        </Link>
      )
    case 'agent_skills_managed':
      return (
        <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }))} to="/agent-library">
          {t('console.brain.manage_skill_in_library')}
        </Link>
      )
    default:
      return undefined
  }
}
