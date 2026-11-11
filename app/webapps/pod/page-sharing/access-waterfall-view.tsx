import { Badge, cn } from '@ankole/uikit'
import { CheckmarkCircleRegular, DismissCircleRegular, FlashRegular, SubtractRegular } from '@ankole/uikit/icons'
import { useTranslation } from 'react-i18next'
import type { PageSharingExplain } from '../content-api'

const STAGE_LABEL_KEYS: Record<string, string> = {
  subject_resolution: 'pod.sharing.stage_subject_resolution',
  space_and_trash_gate: 'pod.sharing.stage_space_and_trash_gate',
  acl_anchor_chain: 'pod.sharing.stage_acl_anchor_chain',
  brain_disclosure_gate: 'pod.sharing.stage_brain_disclosure_gate'
}

function stageStatusText(status: string, t: ReturnType<typeof useTranslation>['t']): string {
  switch (status) {
    case 'pass':
      return t('pod.sharing.stage_status_pass')
    case 'fail':
      return t('pod.sharing.stage_status_fail')
    case 'short_circuit':
      return t('pod.sharing.stage_status_short_circuit')
    default:
      return t('pod.sharing.stage_status_skip')
  }
}

export function AccessWaterfallView({ explain, compact = false }: { explain: PageSharingExplain; compact?: boolean }) {
  const { t } = useTranslation()
  const VerdictIcon = explain.allowed ? CheckmarkCircleRegular : DismissCircleRegular

  return (
    <div className="grid gap-2.5" data-testid="access-waterfall">
      <div
        className={cn(
          'flex items-start justify-between gap-2.5 rounded-control border px-3 py-2 text-xs',
          explain.allowed ? 'border-border bg-bg-secondary/55' : 'border-destructive/35 bg-destructive/5'
        )}>
        <div className="flex min-w-0 items-start gap-2">
          <VerdictIcon
            aria-hidden
            className={cn('mt-0.5 size-4 shrink-0', explain.allowed ? 'text-fg-primary' : 'text-destructive')}
          />
          <div className="min-w-0 space-y-0.5">
            <div className="font-medium text-fg-primary">
              {explain.subject_name}
              {explain.authority_uid !== explain.subject_uid && (
                <span className="ml-1 font-mono text-[11px] font-normal text-fg-tertiary">
                  {`(@${explain.authority_uid})`}
                </span>
              )}
            </div>
            <p className="leading-4 text-fg-secondary">{explain.decision_reason}</p>
          </div>
        </div>
        <Badge variant={explain.allowed ? 'secondary' : 'destructive'} className="shrink-0">
          {explain.allowed
            ? explain.effective_role
              ? `${t('pod.sharing.verdict_allowed')} · ${explain.effective_role}`
              : t('pod.sharing.verdict_allowed')
            : t('pod.sharing.verdict_denied')}
        </Badge>
      </div>

      <ol className="grid gap-1.5">
        {explain.stages.map((stage, index) => {
          const StageIcon =
            stage.status === 'pass'
              ? CheckmarkCircleRegular
              : stage.status === 'fail'
                ? DismissCircleRegular
                : stage.status === 'short_circuit'
                  ? FlashRegular
                  : SubtractRegular
          const badgeVariant =
            stage.status === 'fail' ? 'destructive' : stage.status === 'pass' ? 'secondary' : 'outline'
          const title = t(STAGE_LABEL_KEYS[stage.id] ?? stage.id, { defaultValue: stage.id })

          return (
            <li
              key={stage.id}
              className={cn(
                'rounded-control border border-border/80 px-2.5 py-2 text-xs',
                stage.status === 'skip' ? 'bg-muted/25 opacity-70' : 'bg-bg-primary/60'
              )}>
              <div className="flex items-center justify-between gap-2">
                <span className="inline-flex min-w-0 items-center gap-1.5 font-medium text-fg-primary">
                  <StageIcon
                    aria-hidden
                    className={cn(
                      'size-3.5 shrink-0',
                      stage.status === 'fail' ? 'text-destructive' : 'text-fg-secondary'
                    )}
                  />
                  <span className="truncate">{`${index + 1}. ${title}`}</span>
                </span>
                <Badge variant={badgeVariant} className="shrink-0 px-1.5 py-0 text-[10px]">
                  {stageStatusText(stage.status, t)}
                </Badge>
              </div>
              {(!compact || stage.status !== 'skip') && (
                <p className="mt-1 pl-5 leading-4 text-fg-secondary">{stage.summary}</p>
              )}
            </li>
          )
        })}
      </ol>
    </div>
  )
}
