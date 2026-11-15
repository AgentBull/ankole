import { Button, cn, Input, Popover, PopoverContent, toast } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { sanitizeRenameValue } from '../common/bidi'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode, requestErrorDetails, requestErrorMessage } from '../common/request-errors'
import { limitPageTitle, pageAPI, type Page } from './content-api'
import { contentError } from './content-errors'
import { updatePageMetadata } from './state/navigation-cache'
import { canRenamePage } from './state/page-location'
import { usePageMetadata } from './use-page-metadata'

export function PageRenameField({
  page: sourcePage,
  className,
  saveRef,
  onDone
}: {
  page: Page
  className?: string
  saveRef?: RefObject<(() => Promise<boolean>) | null>
  onDone(): void
}) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const page = usePageMetadata(sourcePage)
  const [value, setValue] = useState(() => sanitizeRenameValue(page.title))
  const expectedTitle = useRef(page.title)
  const [conflictingTitle, setConflictingTitle] = useState<string | null>(null)
  const field = useRef<HTMLInputElement>(null)
  const finished = useRef(false)
  const activePromise = useRef<Promise<unknown> | null>(null)
  const finish = () => {
    finished.current = true
    onDone()
  }
  const rename = useMutation({
    mutationFn: (title: string) => pageAPI.update(page.id, { title, expected_title: expectedTitle.current }),
    onSuccess: (result, title) => {
      updatePageMetadata(client, {
        id: page.id,
        title: result.page?.title ?? title,
        updated_at: result.page?.updated_at
      })
      finish()
    },
    onError: error => {
      finished.current = false
      if (error instanceof InternalAPIError && requestErrorCode(error.payload) === 'title_conflict') {
        const current = requestErrorDetails(error.payload).title
        if (typeof current === 'string') {
          setConflictingTitle(current)
          updatePageMetadata(client, { id: page.id, title: current })
          return
        }
      }
      toast.error(requestErrorMessage(contentError(error)))
    }
  })
  const submitAsync = async (confirmConflict = false, finishIfClean = true): Promise<boolean> => {
    if (!canRenamePage(page)) {
      if (finishIfClean) finish()
      return false
    }
    if (activePromise.current) {
      await activePromise.current.catch(() => {})
      return true
    }
    if (finished.current || rename.isPending) return false
    if (conflictingTitle !== null) {
      if (!confirmConflict) return false
      expectedTitle.current = conflictingTitle
      setConflictingTitle(null)
      const title = value.trim()
      if (title === conflictingTitle) {
        if (finishIfClean) finish()
        return false
      }
      finished.current = true
      const pending = rename.mutateAsync(title).catch(() => {})
      activePromise.current = pending
      try {
        await pending
      } finally {
        if (activePromise.current === pending) activePromise.current = null
      }
      return true
    }
    const title = value.trim()
    if (title === page.title) {
      if (finishIfClean) finish()
      return false
    }
    finished.current = true
    const pending = rename.mutateAsync(title).catch(() => {})
    activePromise.current = pending
    try {
      await pending
    } finally {
      if (activePromise.current === pending) activePromise.current = null
    }
    return true
  }
  const submit = (confirmConflict = false) => {
    void submitAsync(confirmConflict, true)
  }
  const submitAsyncRef = useRef(submitAsync)
  submitAsyncRef.current = submitAsync
  useEffect(() => {
    if (!saveRef) return
    saveRef.current = () => submitAsyncRef.current(false, true)
    return () => {
      saveRef.current = null
    }
  }, [saveRef])
  // A title conflict asks its question in a popover below the field, so the question shows in full wherever the field
  // sits, such as in a sidebar row or in the top bar's path, and the field keeps its focus.
  return (
    <span className="flex min-w-0 flex-1">
      <Input
        ref={field}
        autoFocus
        variant="inline"
        className={cn('pod-tree-rename', className)}
        aria-label={t('pod.sidebar.rename_label', { title: page.title || t('pod.content.untitled') })}
        value={value}
        disabled={rename.isPending}
        placeholder={t('pod.content.untitled')}
        onFocus={event => event.currentTarget.select()}
        onChange={event => setValue(limitPageTitle(event.target.value, value))}
        onBlur={() => submit(false)}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing || event.keyCode === 229) return
          if (event.key === 'Enter') {
            event.preventDefault()
            submit(true)
          } else if (event.key === 'Escape') {
            event.preventDefault()
            finish()
          }
        }}
      />
      <Popover open={conflictingTitle !== null}>
        <PopoverContent
          anchor={field}
          align="start"
          initialFocus={false}
          finalFocus={false}
          className="w-auto max-w-80 gap-2 p-3">
          <span role="alert">{t('pod.document_title.current', { title: conflictingTitle ?? '' })}</span>
          <span className="flex flex-wrap gap-1">
            <Button size="xs" variant="ghost" onClick={finish}>
              {t('pod.document_title.use_current')}
            </Button>
            <Button size="xs" variant="ghost" disabled={rename.isPending} onClick={() => submit(true)}>
              {t('pod.document_title.save_draft')}
            </Button>
          </span>
        </PopoverContent>
      </Popover>
    </span>
  )
}
