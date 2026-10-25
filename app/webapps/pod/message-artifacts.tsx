import { t } from 'i18next'
import { parseMarkdown, printXml } from '@ankole/block-editor/document'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useRef, useState } from 'react'
import { Link } from '@tanstack/react-router'
import type { ConversationMessage } from './api'
import { podKeys, type ConversationAttachment } from './api'
import { podLocation } from '../common/browser-context'
import { podFileCopy } from './api/generated/sdk.gen'
import { contentKeys, pageAPI, pageQuery, pageSearchQuery, type Page, type PageDetail } from './content-api'
import { Choice, ContentError, TextField } from './content-primitives'
import { MessageAttachments } from './chat-attachments'
import { PageIcon } from './page-icon'
import { messageMarkdown } from './chat/export-markdown'
import { RiSaveLine } from '@remixicon/react'

type Message = ConversationMessage

export function MessageArtifacts({ message, conversationID }: { message: Message; conversationID: string }) {
  const pages = message.links.filter(link => link.kind === 'page' && !message.text.includes(`ankole:page/${link.id}`))
  if (!message.attachments.length && !pages.length) return null
  return (
    <div className="mt-2 space-y-2 text-sm">
      <MessageAttachments conversationID={conversationID} messageID={message.id} attachments={message.attachments} />
      {!!pages.length && (
        <ul className="space-y-1">
          {pages.map(link => (
            <li key={link.id}>
              <MessagePageReference id={link.id} />
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap gap-2">
        {message.attachments
          ?.filter(attachment => typeof attachment.path === 'string')
          .map(attachment => (
            <SaveMessageButton
              key={attachment.attachment_id ?? attachment.path}
              message={message}
              attachment={attachment}
              conversationID={conversationID}
            />
          ))}
      </div>
    </div>
  )
}

export function MessagePageReference({ id }: { id: string }) {
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

export function SaveMessageButton({
  message,
  attachment,
  conversationID,
  onSaved
}: {
  message: Message
  attachment?: ConversationAttachment
  conversationID: string
  onSaved?: (page: PageDetail['page']) => void
}) {
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
  const [selectedParent, setParent] = useState<string>()
  const [destinationQuery, setDestinationQuery] = useState('')
  const [selectedPage, setSelectedPage] = useState<Page>()
  const created = useRef<PageDetail['page'] | null>(null)
  const [saved, setSaved] = useState<PageDetail['page']>()
  const pages = useQuery({ ...pageSearchQuery(destinationQuery, { required_action: 'page_edit' }), enabled: open })
  const parent =
    selectedParent ?? (pages.data?.can_create_private ? 'private' : pages.data?.can_create_space ? 'space' : '')
  const destinations = [
    ...new Map(
      [...(pages.data?.pages ?? []), ...(selectedPage ? [selectedPage] : [])].map(page => [page.id, page])
    ).values()
  ]
  const validParent =
    (parent === 'private' && pages.data?.can_create_private === true) ||
    (parent === 'space' && pages.data?.can_create_space === true) ||
    destinations.some(page => page.id === parent)
  const client = useQueryClient()
  const save = useMutation({
    mutationFn: async () => {
      if (!created.current && !validParent) {
        throw new Error(t('pod.content.this_save_location_is_no_longer_available_choose_another_location'))
      }
      if (parent === 'private' && !pages.data?.principal_uid) {
        throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_loading'))
      }
      const xml = attachment ? undefined : printXml(parseMarkdown(messageMarkdown(message)))
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
            data: {
              message_id: message.id,
              path: attachment.path,
              base_revision: page.revision
            }
          }
        })
      } else await pageAPI.write(page.id, page.revision, xml!)
      return page
    },
    onSuccess: async page => {
      await Promise.all([
        client.invalidateQueries({ queryKey: contentKeys.all }),
        client.invalidateQueries({ queryKey: podKeys.detail(conversationID) })
      ])
      setOpen(false)
      setSaved(page)
      onSaved?.(page)
    }
  })
  const cannotSave =
    save.isPending ||
    !pages.data ||
    (!created.current && !validParent) ||
    (parent === 'private' && !pages.data.principal_uid)
  if (saved) {
    return onSaved ? null : (
      <Link className="link pod-chat-saved-page" to={podLocation(`/pages/${saved.id}`).pathname}>
        <PageIcon page={saved} />
        {saved.title || t('pod.content.untitled')}
      </Link>
    )
  }
  return (
    <Dialog open={open} onOpenChange={next => !save.isPending && setOpen(next)}>
      <Button
        size="icon-xs"
        variant="ghost"
        aria-label={
          attachment
            ? t('pod.content.save_file', { value1: String(attachment.name || t('pod.content.attachment')) })
            : t('pod.content.save_as_page')
        }
        title={
          attachment
            ? t('pod.content.save_file', { value1: String(attachment.name || t('pod.content.attachment')) })
            : t('pod.content.save_as_page')
        }
        onClick={() => {
          save.reset()
          setOpen(true)
        }}>
        <RiSaveLine aria-hidden />
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
        <TextField
          label={t('pod.content.search_pages')}
          value={destinationQuery}
          onChange={setDestinationQuery}
          disabled={save.isPending || !!created.current}
        />
        <Choice
          label={t('pod.content.save_to')}
          value={parent}
          onChange={id => {
            setParent(id)
            setSelectedPage(destinations.find(page => page.id === id))
          }}
          disabled={save.isPending || !!created.current}
          options={{
            ...(!parent ? { '': t('pod.content.choose_an_available_destination') } : {}),
            ...(pages.data?.can_create_private ? { private: 'Private' } : {}),
            ...(pages.data?.can_create_space ? { space: t('pod.content.space') } : {}),
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
