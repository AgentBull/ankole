import { Badge, Button, Input, Skeleton, Textarea, buttonVariants, cn, toast } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useBlocker, useNavigate, useParams } from 'react-router'
import {
  ankoleWebBrainControllerCreateObjectMutation,
  ankoleWebBrainControllerListObjectsQueryKey,
  ankoleWebBrainControllerObjectVersionsQueryKey,
  ankoleWebBrainControllerShowObjectOptions,
  ankoleWebBrainControllerShowObjectQueryKey,
  ankoleWebBrainControllerUpdateObjectMutation
} from '../../api/generated/@tanstack/react-query.gen'
import type { BrainObjectPage } from '../../api/generated/types.gen'
import { requestErrorCode, requestErrorDetails, requestErrorMessage } from '../../../common/request-errors'
import { ErrorBlock } from '../../../common/error-block'
import { DiscardConfirmDialog, LabeledField, ReadOnlyValue, ResourceEditorPage } from '../../console-form'
import { BackLink, PageStack } from '../../console-page'
import { MarkdownBody } from '../../markdown-body'
import {
  BrainObjectEditorModel,
  brainObjectSnapshot,
  emptyBrainObjectSnapshot,
  type BrainObjectDraftError
} from '../../state/brain-object-editor-model'
import { brainObjectPath } from './brain-nav'

const MARKDOC_ERROR_CODES = new Set([
  'nested_audience_tag',
  'unopened_audience_tag',
  'unclosed_audience_tag',
  'misplaced_audience_tag'
])

type Translate = (key: string, values?: Record<string, unknown>) => string

export function BrainObjectEditorPage() {
  useSignals()
  const { t } = useTranslation()
  const navigate = useNavigate()
  const params = useParams()
  const queryClient = useQueryClient()
  const model = useModel(BrainObjectEditorModel)
  const allowNavigation = useRef(false)
  const [latest, setLatest] = useState<BrainObjectPage>()
  const slug = params.slug ?? ''
  const mode = slug ? 'edit' : 'new'
  const sourceKey = mode === 'new' ? 'new' : `object:${slug}`

  const detail = useQuery({
    ...ankoleWebBrainControllerShowObjectOptions({ query: { slug } }),
    enabled: mode === 'edit' && Boolean(slug),
    refetchOnMount: 'always'
  })
  const page = detail.data?.object

  useEffect(() => {
    if (mode === 'new') model.initialize(sourceKey, emptyBrainObjectSnapshot())
    else if (page) model.initialize(sourceKey, brainObjectSnapshot(page))
  }, [mode, model, page, sourceKey])

  useEffect(
    () => () => {
      model.reset()
    },
    [model]
  )

  const blocker = useBlocker(useCallback(() => !allowNavigation.current && model.dirty.value, [model]))
  useEffect(() => {
    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!model.dirty.value) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', warnBeforeUnload)
    return () => window.removeEventListener('beforeunload', warnBeforeUnload)
  }, [model])

  const invalidate = (savedSlug: string) => {
    void queryClient.invalidateQueries({ queryKey: ankoleWebBrainControllerListObjectsQueryKey() })
    void queryClient.invalidateQueries({
      queryKey: ankoleWebBrainControllerShowObjectQueryKey({ query: { slug: savedSlug } })
    })
    void queryClient.invalidateQueries({
      queryKey: ankoleWebBrainControllerObjectVersionsQueryKey({ query: { slug: savedSlug } })
    })
  }

  const create = useMutation({
    ...ankoleWebBrainControllerCreateObjectMutation(),
    onSuccess: response => {
      if (!response.object) return
      model.markSaved(response.object)
      invalidate(response.object.slug)
      toast.success(t('console.brain.object_created', { slug: response.object.slug }))
      allowNavigation.current = true
      navigate(brainObjectPath(response.object.slug))
    }
  })
  const update = useMutation({
    ...ankoleWebBrainControllerUpdateObjectMutation(),
    onSuccess: response => {
      if (!response.object) return
      model.markSaved(response.object)
      setLatest(undefined)
      invalidate(response.object.slug)
      toast.success(t('console.brain.object_saved', { slug: response.object.slug }))
    }
  })

  const writeError = mode === 'new' ? create.error : update.error
  const errorCode = requestErrorCode(writeError)
  const diagnostic = markdocDiagnostic(writeError)
  const conflict = errorCode === 'content_hash_conflict'
  const pending = create.isPending || update.isPending
  const initialized = model.sourceKey.value === sourceKey
  const readOnly = mode === 'edit' && page?.editable === false

  const submit = () => {
    model.validationError.value = undefined
    const draftError = model.draftError(mode)
    if (draftError) {
      model.validationError.value = draftError
      return
    }
    if (mode === 'new') create.mutate({ body: model.createBody() })
    else if (page?.editable && model.contentHash.value) update.mutate({ body: model.updateBody() })
  }

  const loadLatest = async () => {
    const result = await detail.refetch()
    if (result.data?.object) {
      setLatest(result.data.object)
      model.useLatestContentHash(result.data.object.content_hash)
    }
  }

  if (mode === 'edit' && detail.isLoading && !initialized) {
    return (
      <PageStack className="mx-auto w-full max-w-6xl">
        <BackLink to="/brain/objects" />
        <Skeleton className="h-12 w-72" />
        <Skeleton className="h-[36rem] w-full" />
      </PageStack>
    )
  }

  if (mode === 'edit' && detail.error && !page) {
    return (
      <PageStack className="mx-auto w-full max-w-6xl">
        <BackLink to="/brain/objects" />
        <ErrorBlock error={detail.error} />
      </PageStack>
    )
  }

  const editorError = model.validationError.value
    ? draftErrorText(model.validationError.value, t)
    : diagnostic || conflict
      ? undefined
      : writeError
        ? requestErrorMessage(writeError)
        : undefined
  const title = mode === 'new' ? t('console.brain.object_create_title') : t('console.brain.object_edit_title')
  const description = readOnly
    ? editBlockText(page?.edit_block_reason, t)
    : t('console.brain.object_editor_description')
  const fields = (
    <>
      <div className="grid gap-5 sm:grid-cols-2">
        <LabeledField label={t('console.brain.slug')} required={mode === 'new'}>
          {mode === 'new' ? (
            <Input
              className="font-mono text-xs"
              disabled={pending}
              spellCheck={false}
              value={model.slug.value}
              onChange={event => (model.slug.value = event.target.value)}
            />
          ) : (
            <ReadOnlyValue mono>{model.slug.value}</ReadOnlyValue>
          )}
        </LabeledField>
        <LabeledField label={t('console.brain.type')} required={mode === 'new'}>
          {mode === 'new' ? (
            <Input
              className="font-mono text-xs"
              disabled={pending}
              spellCheck={false}
              value={model.type.value}
              onChange={event => (model.type.value = event.target.value)}
            />
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

      <LabeledField label={t('console.brain.object_title')} required>
        <Input
          disabled={pending}
          value={model.title.value}
          onChange={event => (model.title.value = event.target.value)}
        />
      </LabeledField>

      <LabeledField
        label={t('console.brain.meta')}
        description={t('console.brain.meta_hint')}
        error={model.validationError.value === 'meta_invalid' ? draftErrorText('meta_invalid', t) : undefined}>
        <Textarea
          className="min-h-28 resize-y font-mono text-xs leading-5"
          disabled={pending}
          spellCheck={false}
          value={model.metaText.value}
          onChange={event => (model.metaText.value = event.target.value)}
        />
      </LabeledField>

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
            {model.preview.value.length ? (
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
          className="grid gap-3 border border-warning/40 bg-warning/5 p-4"
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

  const secondary = editBlockAction(page, t)
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
      error={editorError}
      onSubmit={submit}
      submitDisabled={!model.dirty.value}
      submitUnavailable={mode === 'edit' && !model.contentHash.value}
      submitting={pending}
      title={title}>
      {fields}
    </ResourceEditorPage>
  )

  return (
    <>
      {editor}
      <DiscardConfirmDialog
        open={blocker.state === 'blocked'}
        onKeep={() => blocker.reset?.()}
        onDiscard={() => {
          allowNavigation.current = true
          model.reset()
          blocker.proceed?.()
        }}
      />
    </>
  )
}

function Problems({ diagnostic }: { diagnostic?: { code: string; line?: number } }) {
  const { t } = useTranslation()
  return (
    <section className="grid gap-2 border border-border bg-background p-4" aria-label={t('console.brain.problems')}>
      <h3 className="text-sm font-medium">{t('console.brain.problems')}</h3>
      {diagnostic ? (
        <p className="font-mono text-xs text-destructive">
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

function markdocDiagnostic(error: unknown): { code: string; line?: number } | undefined {
  const code = requestErrorCode(error)
  if (!code || !MARKDOC_ERROR_CODES.has(code)) return undefined
  const line = requestErrorDetails(error).line
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
