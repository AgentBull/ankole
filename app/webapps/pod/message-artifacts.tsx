import { usePageHref, usePageMetadata, usePagesMetadata } from './use-page-metadata'
import {
  Button,
  buttonVariants,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  FileTypeMark,
  Input,
  ReferenceCard
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type ComponentProps, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from '@tanstack/react-router'
import type { ConversationMessage } from './api'
import { podKeys, type ConversationAttachment } from './api'
import {
  cachedPageMap,
  limitPageTitle,
  pageAPI,
  pageQuery,
  pageSearchQuery,
  type Page,
  type PageDetail
} from './content-api'
import { pageCreated } from './state/navigation-cache'
import { ContentError, InlineLoading } from './content-primitives'
import { PagePicker } from './page-picker'
import { MessageAttachments } from './chat-attachments'
import { PageIcon } from './page-icon'
import {
  AppsRegular,
  ArrowDownloadRegular,
  BookOpenRegular,
  DatabaseRegular,
  DocumentTextRegular,
  type IconComponent
} from '@ankole/uikit/icons'

type Message = ConversationMessage

export function MessageArtifacts({ message, conversationID }: { message: Message; conversationID: string }) {
  const pages = message.links.filter(link => link.kind === 'page' && !message.text.includes(`ankole:page/${link.id}`))
  if (!message.attachments.length && !pages.length) return null
  return (
    <div className="pod-chat-attachments">
      <MessageAttachments
        conversationID={conversationID}
        messageID={message.id}
        attachments={message.attachments}
        renderAction={attachment =>
          typeof attachment.path === 'string' ? (
            <SaveAttachmentButton messageID={message.id} attachment={attachment} conversationID={conversationID} />
          ) : null
        }
      />
      {!!pages.length && (
        <ul className="pod-chat-page-references">
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
  return <PageReferenceCard id={id} page={page} title={page.title || t('pod.content.untitled')} />
}

type PageMarkSource = Pick<Page, 'type' | 'icon' | 'system_key'> & { title?: string }

const pageTypeMarks: Partial<Record<Page['type'], IconComponent>> = {
  doc: DocumentTextRegular,
  knowledge: BookOpenRegular,
  base: DatabaseRegular,
  applet: AppsRegular
}

/**
 * The 20px mark of a Page in a reference card. A Page keeps its own icon wherever it appears, so an icon the Page
 * carries comes first; otherwise the card shows its type's mark, and a file Page shows its file's type mark.
 * A Page whose details Pod has not read yet shows the document mark.
 */
function PageMark({ page }: { page?: PageMarkSource }) {
  if (page && (page.icon || page.system_key === 'ankole_brain')) {
    return <PageIcon page={page} className="pod-page-mark" />
  }
  if (page?.type === 'file') return <FileTypeMark fileName={page.title} />
  const Icon = (page && pageTypeMarks[page.type]) || DocumentTextRegular
  return <Icon aria-hidden />
}

/**
 * The Page details Pod has already read, from the Page itself or from navigation, kept current with its title and
 * icon. It never asks the server, so a reference does not add a request of its own.
 */
function useKnownPage(id: string): PageMarkSource | undefined {
  const client = useQueryClient()
  const { data } = useQuery({ ...pageQuery(id), enabled: false })
  return usePageMetadata(data?.page ?? cachedPageMap(client).get(id))
}

/**
 * A reference to a Page as the UI kit's reference card, wherever it stands: in prose, under the message that saved
 * it, and in the summary. It links to the Page; the title is the caller's, such as the Page's title or the text of a
 * Markdown link. Without the caller's `page`, the mark comes from the Page details Pod has already read.
 */
export function PageReferenceCard({
  id,
  title,
  page,
  ...props
}: Omit<ComponentProps<typeof ReferenceCard>, 'mark' | 'render' | 'title' | 'children'> & {
  id: string
  title: ReactNode
  page?: PageMarkSource
}) {
  const pageHref = usePageHref()
  const known = useKnownPage(id)
  const source = page ?? known
  return (
    <ReferenceCard
      {...props}
      mark={<PageMark page={source} />}
      render={<Link to={pageHref(id, source?.title ?? (typeof title === 'string' ? title : undefined))} />}>
      {title}
    </ReferenceCard>
  )
}

function SaveAttachmentButton({
  messageID,
  attachment,
  conversationID
}: {
  messageID: string
  attachment: ConversationAttachment
  conversationID: string
}) {
  const { t } = useTranslation()
  const pageHref = usePageHref()
  const attachmentLabel = String(attachment.name || t('pod.content.attachment'))
  const [open, setOpen] = useState(false)
  const [title, setTitle] = useState(() => attachmentLabel)
  const [selectedParent, setParent] = useState<string>()
  const [selectedPage, setSelectedPage] = useState<Page>()
  const [savedSnapshot, setSaved] = useState<PageDetail['page']>()
  const saved = usePageMetadata(savedSnapshot)
  const pages = useQuery({ ...pageSearchQuery('', { required_action: 'node_edit' }), enabled: open })
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
      const { page } = await pageAPI.create({
        type: 'file',
        title,
        saved_from_message_id: messageID,
        attachment_position: attachment.position,
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
    }
  })
  const cannotSave =
    save.isPending || !pages.data || !validParent || (parent === 'private' && !pages.data.principal_uid)
  if (saved) {
    const savedTitle = saved.title || t('pod.content.untitled')
    // The saved Page also joins the Pages under the message; here the card keeps a way to it in its action's place.
    return (
      <Link
        className={buttonVariants({ variant: 'ghost', size: 'icon-xs' })}
        aria-label={savedTitle}
        title={savedTitle}
        to={pageHref(saved.id, saved.title)}>
        <PageIcon page={saved} />
      </Link>
    )
  }
  const saveLabel = t('pod.content.save_file', { value1: attachmentLabel })
  return (
    <Dialog open={open} onOpenChange={next => !save.isPending && setOpen(next)}>
      <Button
        size="icon-xs"
        variant="ghost"
        className="text-fg-tertiary"
        aria-label={saveLabel}
        title={saveLabel}
        onClick={() => {
          save.reset()
          setTitle(attachmentLabel)
          setOpen(true)
        }}>
        <ArrowDownloadRegular aria-hidden className="size-4" />
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
        <DialogTitle>{t('pod.content.save_file_to_pod')}</DialogTitle>
        <label className="grid gap-1.5 text-sm">
          <span>{t('pod.content.page_title')}</span>
          <Input
            autoFocus
            value={title}
            onChange={event => setTitle(limitPageTitle(event.target.value, title))}
            disabled={save.isPending}
          />
        </label>
        <PagePicker
          autoFocus={false}
          label={t('pod.content.save_to')}
          requiredAction="node_edit"
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
        {pages.isPending && <InlineLoading label={t('pod.content.loading_save_locations')} />}
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
