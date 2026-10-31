import { usePageMetadata, usePagesMetadata } from './use-page-metadata'
import { Button, Dialog, DialogContent, DialogFooter, DialogTitle, Input } from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { Link } from '@tanstack/react-router'
import type { ConversationMessage } from './api'
import { podKeys, type ConversationAttachment } from './api'
import { podLocation } from '../common/browser-context'
import { limitPageTitle, pageAPI, pageQuery, pageSearchQuery, type Page, type PageDetail } from './content-api'
import { pageCreated } from './state/navigation-cache'
import { ContentError } from './content-primitives'
import { PagePicker } from './page-picker'
import { MessageAttachments } from './chat-attachments'
import { PageIcon } from './page-icon'
import { messageMarkdown } from './chat/export-markdown'
import { RiSaveLine } from '@remixicon/react'

type Message = ConversationMessage

function defaultSaveTitle(message: Message, attachment: ConversationAttachment | undefined, t: TFunction) {
  return String(
    attachment?.name ||
      (message.text ?? '')
        .split('\n')[0]
        ?.replace(/^#+\s*/, '')
        .slice(0, 80) ||
      t('pod.content.conversation_artifacts')
  )
}

export function MessageArtifacts({ message, conversationID }: { message: Message; conversationID: string }) {
  const pages = message.links.filter(link => link.kind === 'page' && !message.text.includes(`ankole:page/${link.id}`))
  if (!message.attachments.length && !pages.length) return null
  return (
    <div className="mt-2 space-y-2 text-sm">
      <MessageAttachments
        conversationID={conversationID}
        messageID={message.id}
        attachments={message.attachments}
        renderAction={attachment =>
          typeof attachment.path === 'string' ? (
            <SaveMessageButton message={message} attachment={attachment} conversationID={conversationID} />
          ) : null
        }
      />
      {!!pages.length && (
        <ul className="space-y-1">
          {pages.map(link => (
            <li key={link.id}>
              <MessagePageReference id={link.id} />
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export function MessagePageReference({ id }: { id: string }) {
  const { t } = useTranslation()
  const query = useQuery(pageQuery(id))
  const page = usePageMetadata(query.data?.page)
  if (query.error) return <span className="text-fg-tertiary">{t('pod.content.cannot_display')}</span>
  if (!page) {
    return (
      <span role="status" className="text-fg-tertiary">
        {t('pod.content.loading_page')}
      </span>
    )
  }
  return (
    <Link className="link pod-object-reference" to={podLocation(`/pages/${id}`).pathname}>
      <PageIcon page={page} />
      <span>{page.title || t('pod.content.untitled')}</span>
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
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState(() => defaultSaveTitle(message, attachment, t))
  const [selectedParent, setParent] = useState<string>()
  const [selectedPage, setSelectedPage] = useState<Page>()
  const [savedSnapshot, setSaved] = useState<PageDetail['page']>()
  const saved = usePageMetadata(savedSnapshot)
  const pages = useQuery({ ...pageSearchQuery('', { required_action: 'page_edit' }), enabled: open })
  const parent =
    selectedParent ?? (pages.data?.can_create_private ? 'private' : pages.data?.can_create_space ? 'space' : '')
  const destinations = usePagesMetadata([
    ...new Map(
      [...(pages.data?.pages ?? []), ...(selectedPage ? [selectedPage] : [])].map(page => [page.id, page])
    ).values()
  ])
  const validParent =
    (parent === 'private' && pages.data?.can_create_private === true) ||
    (parent === 'space' && pages.data?.can_create_space === true) ||
    destinations.some(page => page.id === parent)
  const client = useQueryClient()
  const save = useMutation({
    mutationFn: async () => {
      if (!validParent) {
        throw new Error(t('pod.content.this_save_location_is_no_longer_available_choose_another_location'))
      }
      if (parent === 'private' && !pages.data?.principal_uid) {
        throw new Error(t('pod.content.your_private_identity_is_not_available_yet_wait_for_loading'))
      }
      let xml: string | undefined
      if (!attachment) {
        const { parseMarkdown, printXml } = await import('@ankole/block-editor/document')
        xml = printXml(parseMarkdown(messageMarkdown(message)))
      }
      const { page } = await pageAPI.create({
        type: attachment ? 'file' : 'doc',
        title,
        saved_from_message_id: message.id,
        ...(attachment ? { attachment_path: attachment.path } : { xml }),
        ...(parent === 'private'
          ? { private_owner_uid: pages.data!.principal_uid }
          : parent === 'space'
            ? {}
            : { parent_id: parent })
      })
      return page
    },
    onSuccess: async page => {
      await Promise.all([
        pageCreated(client, page),
        client.invalidateQueries({ queryKey: podKeys.detail(conversationID) })
      ])
      setOpen(false)
      setSaved(page)
      onSaved?.(page)
    }
  })
  const cannotSave =
    save.isPending || !pages.data || !validParent || (parent === 'private' && !pages.data.principal_uid)
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
          setTitle(defaultSaveTitle(message, attachment, t))
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
        <label className="grid gap-1.5 text-sm">
          <span>{t('pod.content.page_title')}</span>
          <Input
            autoFocus
            value={title}
            onChange={event => setTitle(limitPageTitle(event.target.value))}
            disabled={save.isPending}
          />
        </label>
        <PagePicker
          autoFocus={false}
          label={t('pod.content.save_to')}
          requiredAction="page_edit"
          selected={parent}
          disabled={save.isPending}
          roots={[
            ...(pages.data?.can_create_private
              ? [{ id: 'private', title: t('pod.content.private'), private: true }]
              : []),
            ...(pages.data?.can_create_space ? [{ id: 'space', title: t('pod.content.space') }] : [])
          ]}
          onSelect={(id, page) => {
            setParent(id)
            setSelectedPage(page)
          }}
        />
        {!pages.isPending && validParent && (
          <p className="pod-selected-destination text-sm">
            {t('pod.content.save_to')}:{' '}
            {parent === 'private'
              ? t('pod.content.private')
              : parent === 'space'
                ? t('pod.content.space')
                : destinations.find(page => page.id === parent)?.title || t('pod.content.untitled')}
          </p>
        )}
        {pages.isPending && <p role="status">{t('pod.content.loading_save_locations')}</p>}
        <ContentError error={pages.error || save.error} retry={pages.error ? () => void pages.refetch() : undefined} />
        <DialogFooter>
          <Button variant="ghost" type="button" disabled={save.isPending} onClick={() => setOpen(false)}>
            {t('pod.content.cancel')}
          </Button>
          <Button variant="outline" type="submit" disabled={cannotSave}>
            {save.isPending ? t('pod.content.saving') : t('pod.content.save')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
