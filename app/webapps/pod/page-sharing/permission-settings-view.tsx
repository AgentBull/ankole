import { usePageMetadata } from '../use-page-metadata'
import { useTranslation } from 'react-i18next'
import { Badge, Button, Switch } from '@ankole/uikit'
import type { PageSharingDetail } from '../content-api'
import { ContentError } from '../content-primitives'
import type { SharingGrant } from '../state/page-sharing'
import { sharingRoleLabel, SubviewHeader } from './sharing-primitives'
import type { PageSharingMutations } from './use-page-sharing'

export function PermissionSettingsView({
  sharing,
  hasParent,
  advancedGrants,
  mutations,
  onBack
}: {
  sharing: PageSharingDetail
  hasParent: boolean
  advancedGrants: readonly SharingGrant[]
  mutations: PageSharingMutations
  onBack(): void
}) {
  const { t } = useTranslation()
  const isPrivateRoot = sharing.scope_kind === 'private' && !hasParent
  const actionLabels = {
    node_view: t('pod.sharing.role_view'),
    node_comment: t('pod.sharing.role_comment'),
    node_contribute: t('pod.sharing.role_contribute'),
    node_edit: t('pod.sharing.role_edit'),
    node_manage: t('pod.sharing.role_manage')
  }

  return (
    <div className="flex min-h-0 flex-col">
      <SubviewHeader title={t('pod.sharing.permission_settings')} disabled={mutations.pending} onBack={onBack} />

      <div className="grid gap-4 overflow-y-auto px-4 pb-4">
        {!isPrivateRoot && (
          <label className="flex items-start justify-between gap-3 rounded-control border border-border p-3 text-sm">
            <div className="min-w-0 flex-1 grid gap-1">
              <span className="font-medium text-foreground">{t('pod.sharing.inherit_switch_label')}</span>
              <span className="text-xs leading-4 text-muted-foreground">{t('pod.sharing.inherit_switch_desc')}</span>
            </div>
            <Switch
              checked={sharing.inherit_permissions}
              disabled={mutations.pending}
              onCheckedChange={checked => mutations.setInheritPermissions(checked)}
              className="mt-0.5"
            />
          </label>
        )}

        <section className="grid gap-2">
          <div className="grid gap-0.5">
            <h3 className="text-[13px] font-medium text-foreground">{t('pod.sharing.advanced_rules_title')}</h3>
            <p className="text-xs leading-4 text-muted-foreground">{t('pod.sharing.advanced_rules_desc')}</p>
          </div>

          {advancedGrants.length === 0 ? (
            <p className="rounded-control bg-muted/40 px-3 py-2.5 text-xs text-muted-foreground">
              {t('pod.sharing.advanced_rules_empty')}
            </p>
          ) : (
            <ul className="grid gap-2">
              {advancedGrants.map((grant, index) => {
                const displayName =
                  grant.kind === 'userset' ? (
                    <SourcePageName source={grant.source_page} />
                  ) : (
                    grant.name || t('pod.content.members_with_access')
                  )
                const selfOnly = grant.target_scope === 'self'
                return (
                  <li key={index} className="grid gap-2 rounded-control border border-border p-2.5 text-sm">
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-1.5">
                        <span className="min-w-0 break-words font-medium">{displayName}</span>
                        <Badge variant="secondary">
                          {selfOnly ? t('pod.content.sharing_scope_self') : t('pod.content.sharing_scope_container')}
                        </Badge>
                      </div>
                      <Button
                        size="xs"
                        variant="ghost"
                        disabled={mutations.pending}
                        onClick={() => mutations.removeGrant(grant)}>
                        {t('pod.sharing.remove_access')}
                      </Button>
                    </div>
                    <div className="rounded-mini bg-muted/60 px-2 py-1.5 text-xs text-muted-foreground">
                      <span>
                        {grant.actions.map(action => actionLabels[action]).join(' · ') || sharingRoleLabel(grant.role)}
                      </span>
                      {grant.source_action && (
                        <span>{` · ${actionLabels[grant.source_action as keyof typeof actionLabels] ?? grant.source_action}`}</span>
                      )}
                      {(grant.condition ?? 'true') !== 'true' && (
                        <code className="mt-1 block break-words text-foreground">{grant.condition}</code>
                      )}
                    </div>
                  </li>
                )
              })}
            </ul>
          )}
        </section>

        <ContentError error={mutations.error} />
      </div>
    </div>
  )
}

function SourcePageName({ source }: { source: SharingGrant['source_page'] }) {
  const { t } = useTranslation()
  const page = usePageMetadata(source?.accessible && source.id ? { id: source.id, title: source.title } : undefined)
  return source?.accessible
    ? (page?.title ?? source.title) || t('pod.content.untitled')
    : t('pod.content.sharing_inaccessible_source')
}
