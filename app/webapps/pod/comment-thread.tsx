import {
  Badge,
  Button,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  Textarea,
  toast
} from '@ankole/uikit'
import { RiCheckLine, RiMoreFill, RiReplyLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { MarkdownBody } from '../common/markdown-body'
import { podLocation } from '../common/browser-context'
import { pageAPI } from './content-api'
import { ContentError } from './content-primitives'
import type { PageCommentsModel } from './state/page-comments'

type Comments = InstanceType<typeof PageCommentsModel>
type Comment = Awaited<ReturnType<typeof pageAPI.comment>>['comment']
type Thread = Awaited<ReturnType<typeof pageAPI.comments>>['threads'][number]

export function CommentThread({
  pageID,
  thread,
  model,
  canComment,
  focused,
  unread,
  hasSelection,
  anchorPending,
  refresh,
  reveal,
  selectAnchor,
  reanchor
}: {
  pageID: string
  thread: Thread
  model: Comments
  canComment: boolean
  focused: boolean
  unread: boolean
  hasSelection: boolean
  anchorPending: boolean
  refresh(): Promise<unknown>
  reveal(): void
  selectAnchor(): void
  reanchor(): Promise<void>
}) {
  const { t } = useTranslation()
  const [replying, setReplying] = useState(false)
  const action = useMutation({
    mutationFn: async (kind: 'resolve' | 'anchor') => {
      if (kind === 'anchor') await reanchor()
      else {
        await pageAPI.resolveComment(pageID, thread.id, !thread.resolved_at, thread.version)
        await refresh()
      }
    },
    onError: () => {
      void refresh()
    }
  })
  return (
    <article
      className="pod-comment-thread mb-3 rounded-(--radius-control) border border-border p-3 data-[focused=true]:bg-selection/40"
      data-thread-id={thread.id}
      data-focused={focused}>
      {unread && <Badge variant="secondary">{t('pod.document.unread_comments')}</Badge>}
      {thread.quote && (
        <>
          <button
            type="button"
            className="pod-comment-quote mb-3 block max-h-[100px] overflow-auto border-l-2 border-border pl-2 text-start text-xs leading-normal whitespace-pre-wrap text-fg-secondary enabled:cursor-pointer [overflow-wrap:anywhere]"
            onClick={reveal}
            disabled={!thread.anchor_present}>
            {thread.quote}
          </button>
          {!thread.anchor_present && <p className="text-xs text-fg-tertiary">{t('pod.document.quote_deleted')}</p>}
          {thread.can_reanchor && !thread.anchor_present && (
            <Button
              variant="ghost"
              size="xs"
              disabled={action.isPending || anchorPending}
              onClick={() => {
                if (hasSelection) action.mutate('anchor')
                else selectAnchor()
              }}>
              {t('pod.document.reanchor')}
            </Button>
          )}
        </>
      )}
      <CommentEntry pageID={pageID} threadID={thread.id} comment={thread} model={model} refresh={refresh} />
      {thread.replies.map(reply => (
        <CommentEntry
          key={reply.id}
          pageID={pageID}
          threadID={thread.id}
          comment={reply}
          model={model}
          refresh={refresh}
        />
      ))}
      <div className="pod-comment-thread-actions flex flex-wrap items-center gap-1">
        {canComment && (
          <Button variant="ghost" size="xs" aria-expanded={replying} onClick={() => setReplying(!replying)}>
            <RiReplyLine aria-hidden />
            {t('pod.document.reply')}
          </Button>
        )}
        {thread.can_resolve && (
          <Button variant="ghost" size="xs" disabled={action.isPending} onClick={() => action.mutate('resolve')}>
            <RiCheckLine aria-hidden />
            {t(thread.resolved_at ? 'pod.document.reopen' : 'pod.document.resolve')}
          </Button>
        )}
        {thread.resolved_at && <span className="text-xs text-fg-tertiary">{t('pod.document.resolved')}</span>}
      </div>
      <ContentError error={action.error} />
      {replying && (
        <CommentComposer
          model={model}
          draftKey={`reply:${thread.id}`}
          label={t('pod.document.reply')}
          disabled={!canComment}
          refresh={refresh}
          send={async body => {
            await pageAPI.comment(pageID, { body, root_id: thread.id })
            model.sent(`reply:${thread.id}`, body)
            await refresh()
          }}
        />
      )}
    </article>
  )
}

function CommentEntry({
  pageID,
  threadID,
  comment,
  model,
  refresh
}: {
  pageID: string
  threadID: string
  comment: Comment
  model: Comments
  refresh(): Promise<unknown>
}) {
  useSignals()
  const { t, i18n } = useTranslation()
  const [editing, setEditing] = useState(false)
  const draftKey = `edit:${comment.id}`
  const editVersion = model.editVersions.value[draftKey]
  const needsReview = editVersion === undefined || comment.version > editVersion
  const remove = useMutation({
    mutationFn: () => pageAPI.deleteComment(pageID, comment.id, comment.version),
    onSuccess: refresh,
    onError: () => {
      void refresh()
    }
  })
  return (
    <div className="pod-comment-entry my-3 [overflow-wrap:anywhere]">
      <header className="mb-1.5 flex items-center gap-2 text-xs">
        <strong className="min-w-0 flex-1">{comment.author.name || comment.author.principal_uid}</strong>
        {comment.author.kind === 'agent' && <Badge variant="secondary">{t('pod.document.agent_author')}</Badge>}
        <time className="text-xs text-fg-tertiary" dateTime={comment.created_at}>
          {new Intl.DateTimeFormat(i18n.language, { dateStyle: 'short', timeStyle: 'short' }).format(
            new Date(comment.created_at)
          )}
        </time>
        <DropdownMenu>
          <DropdownMenuTrigger render={<Button variant="ghost" size="icon-xs" aria-label={t('common.more_actions')} />}>
            <RiMoreFill aria-hidden />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              onClick={async () => {
                try {
                  const target = podLocation(`/pages/${pageID}`, { commentId: threadID })
                  await navigator.clipboard.writeText(new URL(target.pathname + target.search, location.origin).href)
                  toast.success(t('pod.document.comment_link_copied'))
                } catch {
                  toast.error(t('pod.content.could_not_copy_the_link_copy_it_from_the_browser'))
                }
              }}>
              {t('pod.document.copy_comment_link')}
            </DropdownMenuItem>
            {comment.can_edit && (
              <DropdownMenuItem
                onClick={() => {
                  model.beginEdit(draftKey, comment.body ?? '', comment.version)
                  setEditing(true)
                }}>
                {t('pod.document.edit_comment')}
              </DropdownMenuItem>
            )}
            {comment.can_delete && (
              <DropdownMenuItem variant="destructive" disabled={remove.isPending} onClick={() => remove.mutate()}>
                {t('pod.document.delete_comment')}
              </DropdownMenuItem>
            )}
          </DropdownMenuContent>
        </DropdownMenu>
      </header>
      {editing ? (
        <>
          {needsReview && (
            <section
              className="mb-3 grid gap-2 rounded border border-border p-3"
              aria-label={t('pod.document.latest_comment')}>
              <p className="text-xs" role="status">
                {t('pod.document.comment_changed')}
              </p>
              <h3 className="text-xs font-semibold">{t('pod.document.latest_comment')}</h3>
              {comment.deleted_at ? (
                <p className="text-xs">{t('pod.document.comment_deleted')}</p>
              ) : (
                <MarkdownBody text={comment.body ?? ''} />
              )}
              {comment.can_edit && (
                <Button
                  variant="outline"
                  size="xs"
                  className="justify-self-start"
                  onClick={() => model.reviewEdit(draftKey, comment.version)}>
                  {t('pod.document.reviewed_comment_continue')}
                </Button>
              )}
            </section>
          )}
          <CommentComposer
            key={editVersion ?? 'unversioned'}
            model={model}
            draftKey={draftKey}
            label={t('pod.document.edit_comment')}
            disabled={!comment.can_edit || needsReview}
            autoFocus
            refresh={refresh}
            send={async body => {
              if (editVersion === undefined || needsReview) throw new Error(t('pod.document.comment_changed'))
              const result = await pageAPI.editComment(pageID, comment.id, { body, version: editVersion })
              if (model.edited(draftKey, body, editVersion, result.comment.version)) setEditing(false)
              await refresh()
            }}
          />
          <Button variant="ghost" size="xs" onClick={() => setEditing(false)}>
            {t('common.cancel')}
          </Button>
        </>
      ) : comment.deleted_at ? (
        <p className="text-xs text-fg-tertiary">{t('pod.document.comment_deleted')}</p>
      ) : (
        <MarkdownBody text={comment.body ?? ''} />
      )}
      <ContentError error={remove.error} />
    </div>
  )
}

export function CommentComposer({
  model,
  draftKey,
  label,
  disabled,
  submitDisabled = false,
  autoFocus = false,
  send,
  refresh
}: {
  model: Comments
  draftKey: string
  label: string
  disabled: boolean
  submitDisabled?: boolean
  autoFocus?: boolean
  send(body: string): Promise<void>
  refresh(): Promise<unknown>
}) {
  useSignals()
  const { t } = useTranslation()
  const body = model.drafts.value[draftKey] ?? ''
  const mutation = useMutation({
    mutationFn: send,
    onError: () => {
      void refresh()
    }
  })
  return (
    <form
      className="pod-comment-composer grid gap-2"
      onSubmit={event => {
        event.preventDefault()
        if (body.trim() && !disabled && !submitDisabled && !mutation.isPending) mutation.mutate(body)
      }}>
      <Textarea
        autoFocus={autoFocus}
        aria-label={label}
        placeholder={label}
        value={body}
        maxLength={20000}
        readOnly={disabled}
        aria-disabled={disabled}
        onChange={event => model.write(draftKey, event.target.value)}
        rows={3}
      />
      <ContentError error={mutation.error} />
      <Button
        className="justify-self-end"
        size="sm"
        type="submit"
        disabled={disabled || submitDisabled || !body.trim() || mutation.isPending}>
        {t(mutation.isPending ? 'pod.document.sending_comment' : 'pod.document.send_comment')}
      </Button>
    </form>
  )
}
