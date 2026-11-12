import { t as translate } from 'i18next'
import { useTranslation } from 'react-i18next'
import { Button, Popover, PopoverContent, PopoverTitle, PopoverTrigger, toast } from '@ankole/uikit'
import { BuildingRegular, LinkRegular, LockClosedRegular } from '@ankole/uikit/icons'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useState } from 'react'
import { podPublicOrigin } from '../common/browser-context'
import type { Page } from './content-api'
import { ContentError, InlineLoading } from './content-primitives'
import { useResolvePageHref } from './use-page-metadata'
import { CheckAccessView } from './page-sharing/check-access-view'
import { CollaboratorsView } from './page-sharing/collaborators-view'
import { InviteCollaboratorsView } from './page-sharing/invite-view'
import { MainSharingView } from './page-sharing/main-view'
import { PermissionSettingsView } from './page-sharing/permission-settings-view'
import { shareTitle } from './page-sharing/sharing-primitives'
import { usePageSharing, type PageSharingSession } from './page-sharing/use-page-sharing'
import { PageSharingModel } from './state/page-sharing'

export function PageSharingButton({ pageID, page }: { pageID: string; page?: Page }) {
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
        {open && <SharingPopoverBody key={pageID} pageID={pageID} model={model} session={session} />}
      </PopoverContent>
    </Popover>
  )
}

function SharingPopoverBody({
  pageID,
  model,
  session
}: {
  pageID: string
  model: InstanceType<typeof PageSharingModel>
  session: PageSharingSession
}) {
  useSignals()
  const { t } = useTranslation()
  const copyLink = useCopyPageLink(pageID)
  const { sharing, pageType, hasParent, roles, ordinaryGrants, advancedGrants, directByKey, mutations } = session

  if (!sharing) {
    return (
      <div className="grid gap-3 p-4">
        <div className="flex items-center justify-between gap-2">
          <PopoverTitle>{shareTitle(pageType)}</PopoverTitle>
        </div>
        <ContentError error={session.sharingError} retry={session.retrySharing} />
        {!session.sharingError && <InlineLoading label={t('pod.content.loading_sharing_settings')} />}
        <div className="flex items-center justify-between border-t border-border pt-3">
          <Button variant="outline" size="sm" onClick={() => void copyLink()}>
            <LinkRegular aria-hidden className="size-4" />
            {t('pod.content.copy_link')}
          </Button>
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
        model={model}
        sharing={sharing}
        ordinaryGrants={ordinaryGrants}
        roles={roles}
        canManage={canManage}
        mutations={mutations}
        copyLink={copyLink}
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
      copyLink={copyLink}
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
