import { useTranslation } from 'react-i18next'
import {
  Button,
  RadioGroup,
  RadioGroupItem,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue
} from '@ankole/uikit'
import { RiCloseLine, RiRobot2Line } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import type { PageRole, PageSharingDetail, PageType } from '../content-api'
import { ContentError } from '../content-primitives'
import { subjectKey, type PageSharingModel, type SharingGrant } from '../state/page-sharing'
import { sharingRoleLabel, SubviewHeader } from './sharing-primitives'
import { SubjectPicker } from './subject-picker'
import type { PageSharingMutations } from './use-page-sharing'

export function InviteCollaboratorsView({
  pageType,
  model,
  sharing,
  directByKey,
  roles,
  mutations,
  onBack
}: {
  pageType?: PageType
  model: InstanceType<typeof PageSharingModel>
  sharing: PageSharingDetail
  directByKey: ReadonlyMap<string, SharingGrant>
  roles: Partial<Record<PageRole, string>>
  mutations: PageSharingMutations
  onBack(): void
}) {
  useSignals()
  const { t } = useTranslation()
  const isPrivate = sharing.scope_kind === 'private'
  const stagedKeys = model.stagedKeys.value
  const candidates = sharing.subjects.filter(subject => !stagedKeys.has(subjectKey(subject)))

  const confirmInvite = async () => {
    const patch = model.buildInvitePatch()
    if (!patch) return
    try {
      await mutations.submitPatch(patch)
      model.backToMain()
    } catch {
      // Mutation error stays visible inside the invite view so the selection is preserved.
    }
  }

  return (
    <div className="flex min-h-0 flex-col">
      <SubviewHeader title={t('pod.sharing.add_collaborators')} disabled={mutations.pending} onBack={onBack} />

      <div className="grid gap-3.5 overflow-y-auto px-4 pb-3.5">
        {model.staged.value.length > 0 && (
          <div className="flex flex-wrap gap-1.5 rounded-control border border-border bg-muted/35 p-2">
            {model.staged.value.map(subject => {
              const key = subjectKey(subject)
              return (
                <span
                  key={key}
                  className="inline-flex max-w-full items-center gap-1.5 rounded-control bg-background px-2 py-1 text-xs text-foreground shadow-2xs ring-1 ring-border">
                  <span className="truncate font-medium">{subject.name}</span>
                  <button
                    type="button"
                    aria-label={t('pod.content.remove_2', { value1: subject.name })}
                    disabled={mutations.pending}
                    onClick={() => model.unstageSubject(key)}
                    className="inline-flex size-4 shrink-0 cursor-pointer items-center justify-center rounded-mini text-muted-foreground hover:bg-accent hover:text-foreground disabled:cursor-not-allowed">
                    <RiCloseLine aria-hidden className="size-3.5" />
                  </button>
                </span>
              )
            })}
          </div>
        )}

        <SubjectPicker
          subjects={candidates}
          directByKey={directByKey}
          roles={roles}
          pageType={pageType}
          isPrivate={isPrivate}
          query={model.query.value}
          onQueryChange={value => {
            model.query.value = value
          }}
          disabled={mutations.pending}
          onSelectSubject={subject => model.stageSubject(subject)}
        />

        <div className="grid gap-3 rounded-control border border-border p-3">
          <div className="flex items-center justify-between gap-3">
            <span className="text-xs font-medium text-muted-foreground">{t('pod.content.permission_to_grant')}</span>
            <Select<PageRole>
              value={model.stagedRole.value}
              disabled={mutations.pending}
              onValueChange={next => {
                if (next) model.stagedRole.value = next
              }}>
              <SelectTrigger size="sm" aria-label={t('pod.content.permission_to_grant')} className="min-w-32">
                <SelectValue>
                  {() => roles[model.stagedRole.value] ?? sharingRoleLabel(model.stagedRole.value, pageType)}
                </SelectValue>
              </SelectTrigger>
              <SelectContent align="end">
                {Object.entries<string | undefined>(roles).map(([roleKey, label]) => (
                  <SelectItem key={roleKey} value={roleKey as PageRole}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid gap-2">
            <span className="text-xs font-medium text-muted-foreground">{t('pod.sharing.scope_label')}</span>
            <RadioGroup
              value={model.stagedScope.value}
              disabled={mutations.pending}
              onValueChange={next => {
                if (next === 'container' || next === 'self') model.stagedScope.value = next
              }}
              className="grid gap-2">
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <RadioGroupItem value="container" />
                <span>{t('pod.sharing.tab_container')}</span>
              </label>
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <RadioGroupItem value="self" />
                <span>{t('pod.sharing.tab_self')}</span>
              </label>
            </RadioGroup>
          </div>
        </div>

        {model.hasStagedAgents.value && (
          <div className="flex items-start gap-2 rounded-control bg-muted/55 p-2.5 text-xs leading-4 text-muted-foreground">
            <RiRobot2Line aria-hidden className="mt-0.5 size-4 shrink-0 text-foreground" />
            <span>{t('pod.sharing.agent_hint')}</span>
          </div>
        )}

        <ContentError error={mutations.error} />
      </div>

      <div className="flex items-center justify-end gap-2 border-t border-border px-4 py-2.5">
        <Button variant="ghost" size="sm" disabled={mutations.pending} onClick={onBack}>
          {t('pod.content.cancel')}
        </Button>
        <Button
          size="sm"
          disabled={mutations.pending || model.staged.value.length === 0}
          onClick={() => void confirmInvite()}>
          {mutations.pending ? t('pod.content.saving') : t('pod.sharing.confirm')}
        </Button>
      </div>
    </div>
  )
}
