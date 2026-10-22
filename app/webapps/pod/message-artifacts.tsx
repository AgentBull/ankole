import { t } from 'i18next'
import { parseMarkdown, printXml } from '@ankole/block-editor/document'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import type { ConversationMessage } from './api'
import type { ConversationAttachment } from '../common/api/generated/types.gen'
import { podLocation } from '../common/browser-context'
import { podFileCopy } from '../common/api/generated/sdk.gen'
import { contentKeys, pageAPI, pageQuery, pagesQuery, type Page } from './content-api'
import { Choice, ContentError, TextField } from './content-primitives'
import { MessageAttachments } from './chat-attachments'
import { PageIcon } from './page-icon'

type Message = ConversationMessage

export function MessageArtifacts({ message, conversationID }: { message: Message; conversationID?: string }) {
  return (
    <div className="mt-2 space-y-2 text-sm">
      {conversationID && (
        <MessageAttachments conversationID={conversationID} messageID={message.id} attachments={message.attachments} />
      )}
      {!!message.links?.length && (
        <ul className="space-y-1">
          {message.links
            .filter(link => link.kind === 'page' && typeof link.id === 'string')
            .map(link => (
              <li key={String(link.id)}>
                <MessagePageReference id={String(link.id)} />
              </li>
            ))}
        </ul>
      )}
      <div className="flex flex-wrap gap-2">
        {!!message.text.trim() && <SaveMessageButton message={message} />}
        {message.attachments
          ?.filter(attachment => typeof attachment.path === 'string')
          .map(attachment => (
            <SaveMessageButton
              key={attachment.attachment_id ?? attachment.path}
              message={message}
              attachment={attachment}
            />
          ))}
      </div>
    </div>
  )
}

function MessagePageReference({ id }: { id: string }) {
  const page = useQuery(pageQuery(id))
  if (page.error) return <span className="text-fg-tertiary">{t('pod.content.cannot_display')}</span>
  if (!page.data) {
    return (
      <span role="status" className="text-fg-tertiary">
        {t('pod.content.loading_page')}
      </span>
    )
  }
  return (
    <Link className="link pod-object-reference" to={podLocation(`/pages/${id}`).pathname}>
      <PageIcon page={page.data.page} />
      <span>{page.data.page.title || t('pod.content.untitled')}</span>
    </Link>
  )
}

function SaveMessageButton({ message, attachment }: { message: Message; attachment?: ConversationAttachment }) {
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState(
    String(
      attachment?.name ||
        (message.text ?? '')
          .split('\n')[0]
          ?.replace(/^#+\s*/, '')
          .slice(0, 80) ||
        t('pod.content.conversation_artifacts')
    )
  )
  const [parent, setParent] = useState('private')
  const created = useRef<Page | null>(null)
  const pages = useQuery({ ...pagesQuery('all'), enabled: open })
  const destinations = (pages.data?.pages ?? []).filter(
    page => page.type === 'doc' && (page.role === 'edit' || page.role === 'manage')
  )
  const validParent = parent === 'private' || parent === 'space' || destinations.some(page => page.id === parent)
  const client = useQueryClient(),
    navigate = useNavigate()
  const save = useMutation({
    mutationFn: async () => {
      if (!created.current && !validParent) {
        throw new Error(t('pod.content.this_save_location_is_no_longer_available_choose_another_location'))
      }
      if (parent === 'private' && !pages.data?.principal_uid) {
        throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_loading'))
      }
      const xml = attachment ? undefined : printXml(parseMarkdown(message.text ?? ''))
      const page =
        created.current ??
        (
          await pageAPI.create({
            type: attachment ? 'file' : 'doc',
            title,
            saved_from_message_id: message.id,
            ...(parent === 'private'
              ? { private_owner_uid: pages.data!.principal_uid }
              : parent === 'space'
                ? {}
                : { parent_id: parent })
          })
        ).page
      created.current = page
      if (attachment) {
        await podFileCopy({
          path: { id: page.id },
          body: {
            message_id: message.id,
            path: attachment.path,
            base_revision: page.revision
          }
        })
      } else await pageAPI.write(page.id, page.revision, xml!)
      return page
    },
    onSuccess: async page => {
      await client.invalidateQueries({ queryKey: contentKeys.all })
      setOpen(false)
      void navigate({ to: podLocation(`/pages/${page.id}`).pathname })
    }
  })
  const cannotSave =
    save.isPending ||
    !pages.data ||
    (!created.current && !validParent) ||
    (parent === 'private' && !pages.data.principal_uid)
  return (
    <Dialog open={open} onOpenChange={next => !save.isPending && setOpen(next)}>
      <Button
        size="xs"
        variant="ghost"
        onClick={() => {
          save.reset()
          setOpen(true)
        }}>
        {attachment
          ? t('pod.content.save_file', { value1: String(attachment.name || t('pod.content.attachment')) })
          : t('pod.content.save_as_page')}
      </Button>
      <DialogContent
        className="pod-dialog"
        closeLabel={t('common.close')}
        showCloseButton={!save.isPending}
        render={
          <form
            onSubmit={event => {
              event.preventDefault()
              if (!cannotSave) save.mutate()
            }}
          />
        }>
        <DialogTitle>
          {attachment ? t('pod.content.save_file_to_pod') : t('pod.content.save_conversation_artifact')}
        </DialogTitle>
        <TextField
          label={t('pod.content.page_title')}
          value={title}
          onChange={setTitle}
          disabled={save.isPending || !!created.current}
        />
        <Choice
          label={t('pod.content.save_to')}
          value={parent}
          onChange={setParent}
          disabled={save.isPending || !!created.current}
          options={{
            private: 'Private',
            space: t('pod.content.space'),
            ...Object.fromEntries(destinations.map(page => [page.id, page.title || t('pod.content.untitled')]))
          }}
        />
        {pages.isPending && <p role="status">{t('pod.content.loading_save_locations')}</p>}
        <ContentError error={pages.error || save.error} retry={pages.error ? () => void pages.refetch() : undefined} />
        {save.error && created.current && (
          <p className="text-sm">
            {t('pod.content.the_page_was_created_but_its_content_has_not_been')}{' '}
            <Link className="link" to={podLocation(`/pages/${created.current.id}`).pathname}>
              {t('pod.content.open_the_created_page')}
            </Link>
          </p>
        )}
        <DialogFooter>
          <Button variant="ghost" type="button" disabled={save.isPending} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button variant="outline" type="submit" disabled={cannotSave}>
            {save.isPending
              ? t('pod.content.saving')
              : created.current
                ? t('pod.content.retry_save')
                : t('pod.content.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
