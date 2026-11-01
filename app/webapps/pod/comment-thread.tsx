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
import { RiAtLine, RiCheckLine, RiMoreFill, RiReplyLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { MarkdownBody } from '../common/markdown-body'
import { podLocation } from '../common/browser-context'
import { agentsQuery, type PodAgent } from './api'
import { completionAt } from './chat/composer-completion'
import { pageAPI } from './content-api'
import { ContentError } from './content-primitives'
import { formatFileAnchorLabel, parseFileCommentAnchor, type FileCommentAnchor } from './file-comment-anchors'
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
  reveal(anchor?: FileCommentAnchor | null): void
  selectAnchor(): void
  reanchor(): Promise<void>
}) {
  const { t } = useTranslation()
  const [replying, setReplying] = useState(false)
  const parsedAnchor = parseFileCommentAnchor(thread.anchor ?? null)
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
  const showAnchorBlock = Boolean(thread.quote || parsedAnchor)
  return (
    <article
      className="pod-comment-thread mb-3 rounded-(--radius-control) border border-border p-3 data-[focused=true]:bg-selection/40"
      data-thread-id={thread.id}
      data-focused={focused}>
      {unread && <Badge variant="secondary">{t('pod.document.unread_comments')}</Badge>}
      {showAnchorBlock && (
        <div className="mb-3 space-y-1.5">
          {parsedAnchor && (
            <div className="flex flex-wrap items-center gap-1.5">
              <button
                type="button"
                disabled={!thread.anchor_present}
                onClick={() => reveal(parsedAnchor)}
                className="inline-flex items-center rounded border border-border bg-muted/50 px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary enabled:cursor-pointer enabled:hover:border-border-strong enabled:hover:text-foreground disabled:opacity-60">
                {formatFileAnchorLabel(parsedAnchor)}
              </button>
              {thread.anchor_outdated && (
                <Badge variant="outline" className="text-warning-foreground">
                  {t('pod.document.anchor_outdated', { defaultValue: 'Anchor from an earlier file version' })}
                </Badge>
              )}
            </div>
          )}
          {thread.quote && (
            <button
              type="button"
              className="pod-comment-quote block max-h-[100px] overflow-auto border-l-2 border-border pl-2 text-start text-xs leading-normal whitespace-pre-wrap text-fg-secondary enabled:cursor-pointer [overflow-wrap:anywhere]"
              onClick={() => reveal(parsedAnchor)}
              disabled={!thread.anchor_present}>
              {thread.quote}
            </button>
          )}
          {!thread.anchor_present && !thread.anchor_outdated && (
            <p className="text-xs text-fg-tertiary">{t('pod.document.quote_deleted')}</p>
          )}
          {thread.can_reanchor && (!thread.anchor_present || thread.anchor_outdated) && (
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
        </div>
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
          send={async (body, mentionedAgentUIDs) => {
            await pageAPI.comment(pageID, {
              body,
              root_id: thread.id,
              ...(mentionedAgentUIDs.length ? { mentioned_agent_uids: mentionedAgentUIDs } : {})
            })
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
            send={async (body, mentionedAgentUIDs) => {
              if (editVersion === undefined || needsReview) throw new Error(t('pod.document.comment_changed'))
              const result = await pageAPI.editComment(pageID, comment.id, {
                body,
                version: editVersion,
                ...(mentionedAgentUIDs.length ? { mentioned_agent_uids: mentionedAgentUIDs } : {})
              })
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

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function hasMentionToken(body: string, token: string): boolean {
  if (!token) return false
  const re = new RegExp(`(?<![\\p{L}\\p{N}_-])@${escapeRegExp(token)}(?![\\p{L}\\p{N}_-])`, 'iu')
  return re.test(body)
}

export function collectMentionedAgentUIDs(
  body: string,
  agents: Pick<PodAgent, 'uid' | 'displayName'>[],
  selectedUIDs?: ReadonlySet<string>
): string[] {
  const uids = new Set<string>()
  for (const match of body.matchAll(/<mention\b[^>]*\buid="([^"]+)"/giu)) {
    if (match[1]) uids.add(match[1])
  }
  for (const match of body.matchAll(/@\[[^\]]*\]\(principal:([^)\s]+)\)/giu)) {
    if (match[1]) uids.add(match[1])
  }

  const byLowerName = new Map<string, Pick<PodAgent, 'uid' | 'displayName'>[]>()
  for (const agent of agents) {
    if (hasMentionToken(body, agent.uid)) {
      uids.add(agent.uid)
    }
    const name = agent.displayName?.trim()
    if (name) {
      const key = name.toLowerCase()
      byLowerName.set(key, [...(byLowerName.get(key) ?? []), agent])
    }
  }

  for (const [lowerName, group] of byLowerName) {
    if (!hasMentionToken(body, lowerName)) continue
    const explicitlyPicked = selectedUIDs ? group.filter(agent => selectedUIDs.has(agent.uid)) : []
    for (const target of explicitlyPicked.length > 0 ? explicitlyPicked : group) {
      uids.add(target.uid)
    }
  }

  return [...uids]
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
  send(body: string, mentionedAgentUIDs: string[]): Promise<void>
  refresh(): Promise<unknown>
}) {
  useSignals()
  const { t } = useTranslation()
  const listboxID = useId()
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const [mentionMatch, setMentionMatch] = useState<{ start: number; end: number; query: string } | null>(null)
  const [activeIndex, setActiveIndex] = useState(0)
  const [selectedAgentUIDs, setSelectedAgentUIDs] = useState<Set<string>>(() => new Set())
  const agents = useQuery({ ...agentsQuery, enabled: !disabled })
  const callableAgents = [
    ...(agents.data?.agents ?? []),
    ...(agents.data?.personalAssistant ? [agents.data.personalAssistant] : [])
  ].filter(agent => agent.active)
  const matchingAgents = mentionMatch
    ? callableAgents.filter(agent => {
        const q = mentionMatch.query.trim().toLowerCase()
        if (!q) return true
        return [agent.displayName, agent.uid, ...(agent.aliases ?? [])].some(value => value.toLowerCase().includes(q))
      })
    : []

  const body = model.drafts.value[draftKey] ?? ''
  const mutation = useMutation({
    mutationFn: (text: string) => send(text, collectMentionedAgentUIDs(text, callableAgents, selectedAgentUIDs)),
    onSuccess: () => {
      setMentionMatch(null)
      setSelectedAgentUIDs(new Set())
    },
    onError: () => {
      void refresh()
    }
  })

  const updateMentionFromInput = (value: string, start: number | null, end: number | null) => {
    if (start === null || end === null) {
      setMentionMatch(null)
      return
    }
    const found = completionAt(value, start, end)
    if (found?.kind === 'mention') {
      setMentionMatch({ start: found.start, end: found.end, query: found.query })
      setActiveIndex(0)
    } else {
      setMentionMatch(null)
    }
  }

  const insertAgentMention = (agent: PodAgent) => {
    if (!mentionMatch) return
    const token = `@${agent.displayName} `
    const nextValue = `${body.slice(0, mentionMatch.start)}${token}${body.slice(mentionMatch.end)}`
    const nextCaret = mentionMatch.start + token.length
    model.write(draftKey, nextValue)
    setSelectedAgentUIDs(prev => new Set([...prev, agent.uid]))
    setMentionMatch(null)
    requestAnimationFrame(() => {
      textareaRef.current?.focus()
      textareaRef.current?.setSelectionRange(nextCaret, nextCaret)
    })
  }

  return (
    <form
      className="pod-comment-composer relative grid gap-2"
      onSubmit={event => {
        event.preventDefault()
        if (body.trim() && !disabled && !submitDisabled && !mutation.isPending) mutation.mutate(body)
      }}>
      {mentionMatch && matchingAgents.length > 0 && (
        <div
          id={listboxID}
          role="listbox"
          aria-label={t('pod.document.mention_agent', { defaultValue: 'Mention an Agent' })}
          className="max-h-40 overflow-auto rounded-control border border-border bg-popover p-1 text-xs shadow-md">
          {matchingAgents.map((agent, index) => (
            <button
              key={agent.uid}
              type="button"
              role="option"
              aria-selected={index === activeIndex}
              onMouseDown={event => {
                event.preventDefault()
                insertAgentMention(agent)
              }}
              className={`flex w-full items-center justify-between gap-2 rounded px-2 py-1.5 text-left ${
                index === activeIndex ? 'bg-accent text-foreground' : 'text-fg-secondary hover:bg-accent/50'
              }`}>
              <span className="truncate font-medium">@{agent.displayName}</span>
              <Badge variant="secondary">{t('pod.document.agent_author')}</Badge>
            </button>
          ))}
        </div>
      )}
      <Textarea
        ref={textareaRef}
        autoFocus={autoFocus}
        aria-label={label}
        aria-controls={mentionMatch && matchingAgents.length > 0 ? listboxID : undefined}
        placeholder={label}
        value={body}
        maxLength={20000}
        readOnly={disabled}
        aria-disabled={disabled}
        onChange={event => {
          const next = event.target.value
          model.write(draftKey, next)
          updateMentionFromInput(next, event.target.selectionStart, event.target.selectionEnd)
        }}
        onKeyDown={event => {
          if (mentionMatch && matchingAgents.length > 0) {
            if (event.key === 'ArrowDown') {
              event.preventDefault()
              setActiveIndex(prev => (prev + 1) % matchingAgents.length)
              return
            }
            if (event.key === 'ArrowUp') {
              event.preventDefault()
              setActiveIndex(prev => (prev - 1 + matchingAgents.length) % matchingAgents.length)
              return
            }
            if (event.key === 'Enter' || event.key === 'Tab') {
              const target = matchingAgents[activeIndex]
              if (target) {
                event.preventDefault()
                insertAgentMention(target)
                return
              }
            }
            if (event.key === 'Escape') {
              event.preventDefault()
              setMentionMatch(null)
              return
            }
          }
        }}
        rows={3}
      />
      <ContentError error={mutation.error} />
      <div className="flex items-center justify-between gap-2">
        {!disabled && callableAgents.length > 0 ? (
          <Button
            type="button"
            size="xs"
            variant="ghost"
            onClick={() => {
              const input = textareaRef.current
              const pos = input?.selectionStart ?? body.length
              const prefix = pos > 0 && !/\s/.test(body[pos - 1]!) ? ' @' : '@'
              const next = `${body.slice(0, pos)}${prefix}${body.slice(pos)}`
              const caret = pos + prefix.length
              model.write(draftKey, next)
              updateMentionFromInput(next, caret, caret)
              requestAnimationFrame(() => {
                input?.focus()
                input?.setSelectionRange(caret, caret)
              })
            }}>
            <RiAtLine aria-hidden />
            {t('pod.document.mention_agent_button', { defaultValue: 'Mention Agent' })}
          </Button>
        ) : (
          <span />
        )}
        <Button size="sm" type="submit" disabled={disabled || submitDisabled || !body.trim() || mutation.isPending}>
          {t(mutation.isPending ? 'pod.document.sending_comment' : 'pod.document.send_comment')}
        </Button>
      </div>
    </form>
  )
}
