import { t as translate } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Button, Popover, PopoverContent, PopoverTitle, PopoverTrigger, toast } from '@ankole/uikit'
import { BuildingRegular, LockClosedRegular } from '@ankole/uikit/icons'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { podPublicOrigin } from '../common/browser-context'
import { contentKeys, type Page, type PageDetail } from './content-api'
import { ContentError, InlineLoading } from './content-primitives'
import { usePageMetadata, useResolvePageHref } from './use-page-metadata'
import { CheckAccessView } from './page-sharing/check-access-view'
import { CollaboratorsView } from './page-sharing/collaborators-view'
import { InviteCollaboratorsView } from './page-sharing/invite-view'
import { MainSharingView } from './page-sharing/main-view'
import { PermissionSettingsView } from './page-sharing/permission-settings-view'
import { PageShareLinkField, SharePagePreview } from './page-sharing/share-preview'
import { shareTitle } from './page-sharing/sharing-primitives'
import { usePageSharing, type PageSharingSession } from './page-sharing/use-page-sharing'
import { PageSharingModel } from './state/page-sharing'

export function PageSharingButton({
  pageID,
  page,
  title,
  bodyXML
}: {
  pageID: string
  page?: Page
  title?: string | null
  bodyXML?: string | null
}) {
  useSignals()
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const model = useModel(PageSharingModel)
  const session = usePageSharing(pageID, { open, initialPage: page })
  const ScopeIcon = session.restricted ? LockClosedRegular : BuildingRegular

  return (
    <Popover
      open={open}
      onOpenChange={next => {
        if (!next && session.mutations.pending) return
        session.mutations.clearError()
        if (!next) model.reset()
        setOpen(next)
      }}>
      <PopoverTrigger
        render={
          <Button variant="ghost" size="icon-lg" aria-label={t('pod.content.share')} title={t('pod.content.share')} />
        }>
        <ScopeIcon aria-hidden />
      </PopoverTrigger>
      <PopoverContent
        align="end"
        sideOffset={8}
        className="max-h-[min(76vh,var(--available-height))] w-[min(28rem,calc(100vw-2rem))] gap-0 overflow-hidden p-0">
        {open && (
          <SharingPopoverBody
            key={pageID}
            pageID={pageID}
            initialPage={page}
            title={title}
            bodyXML={bodyXML}
            model={model}
            session={session}
          />
        )}
      </PopoverContent>
    </Popover>
  )
}

function SharingPopoverBody({
  pageID,
  initialPage,
  title,
  bodyXML,
  model,
  session
}: {
  pageID: string
  initialPage?: Page
  title?: string | null
  bodyXML?: string | null
  model: InstanceType<typeof PageSharingModel>
  session: PageSharingSession
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const cachedDetail = client.getQueryData<PageDetail>(contentKeys.page(pageID))
  const resolvedPage = usePageMetadata(initialPage ?? cachedDetail?.page)
  const resolvedTitle = title ?? resolvedPage?.title
  const resolvedBodyXML = bodyXML ?? cachedDetail?.content?.content
  const { sharing, pageType, hasParent, roles, ordinaryGrants, advancedGrants, directByKey, mutations } = session
  const previewCard = resolvedPage ? (
    <SharePagePreview
      page={resolvedPage}
      title={resolvedTitle}
      bodyXML={resolvedBodyXML}
      restricted={session.restricted}
      scopeLabel={
        sharing
          ? sharing.scope_kind === 'private'
            ? t('pod.sharing.scope_private_root')
            : sharing.inherit_permissions
              ? sharing.space_name || t('pod.sharing.scope_space_fallback')
              : t('pod.sharing.scope_invited_only')
          : undefined
      }
    />
  ) : null

  if (!sharing) {
    return (
      <div className="grid gap-3 p-4">
        <div className="flex items-center justify-between gap-2">
          <PopoverTitle>{shareTitle(pageType)}</PopoverTitle>
        </div>
        {previewCard}
        <ContentError error={session.sharingError} retry={session.retrySharing} />
        {!session.sharingError && <InlineLoading label={t('pod.content.loading_sharing_settings')} />}
        <div className="border-t border-border-subtle pt-3">
          <PageShareLinkField pageID={pageID} title={resolvedTitle} />
        </div>
      </div>
    )
  }

  const canManage = sharing.can_manage
  const view = canManage
    ? model.view.value
    : model.view.value === 'collaborators' || model.view.value === 'explain'
      ? model.view.value
      : 'main'
  const backToMain = () => {
    mutations.clearError()
    model.backToMain()
  }

  if (view === 'explain') {
    return (
      <CheckAccessView
        pageID={pageID}
        sharing={sharing}
        canManage={canManage}
        mutations={mutations}
        onBack={backToMain}
      />
    )
  }

  if (view === 'invite') {
    return (
      <InviteCollaboratorsView
        pageType={pageType}
        model={model}
        sharing={sharing}
        directByKey={directByKey}
        roles={roles}
        mutations={mutations}
        onBack={backToMain}
      />
    )
  }

  if (view === 'collaborators') {
    return (
      <CollaboratorsView
        pageID={pageID}
        pageTitle={resolvedTitle}
        model={model}
        sharing={sharing}
        ordinaryGrants={ordinaryGrants}
        roles={roles}
        canManage={canManage}
        mutations={mutations}
        onBack={backToMain}
        onOpenInvite={scope => {
          mutations.clearError()
          model.openInvite(scope, 'view')
        }}
      />
    )
  }

  if (view === 'settings') {
    return (
      <PermissionSettingsView
        sharing={sharing}
        hasParent={hasParent}
        advancedGrants={advancedGrants}
        mutations={mutations}
        onBack={backToMain}
      />
    )
  }

  return (
    <MainSharingView
      pageID={pageID}
      pageTitle={resolvedTitle}
      preview={previewCard}
      pageType={pageType}
      hasParent={hasParent}
      model={model}
      sharing={sharing}
      ordinaryGrants={ordinaryGrants}
      directByKey={directByKey}
      advancedCount={advancedGrants.length}
      roles={roles}
      canManage={canManage}
      mutations={mutations}
      onOpenCollaborators={() => {
        mutations.clearError()
        model.openCollaborators('container')
      }}
      onOpenSettings={() => {
        mutations.clearError()
        model.openSettings()
      }}
      onOpenExplain={() => {
        mutations.clearError()
        model.openExplain()
      }}
      onStageSubject={(subject, defaultRole, defaultScope) => {
        mutations.clearError()
        model.stageSubject(subject, defaultRole, defaultScope)
      }}
    />
  )
}

export function useCopyPageLink(pageID: string, title?: string | null) {
  const resolvePageHref = useResolvePageHref()
  const copy = async () => {
    try {
      const href = await resolvePageHref(pageID, title)
      await navigator.clipboard.writeText(new URL(href, podPublicOrigin()).href)
      toast.success(translate('pod.content.page_link_copied'))
    } catch {
      toast.error(translate('pod.content.could_not_copy_the_link_copy_it_from_the_browser'))
    }
  }
  return copy
}
