import {
  Avatar,
  AvatarDot,
  AvatarFallback,
  AvatarImage,
  Button,
  Popover,
  PopoverContent,
  PopoverTrigger,
  Spinner
} from '@ankole/uikit'
import { CheckmarkCircleRegular, CloudOffRegular } from '@ankole/uikit/icons'
import { useSignals } from '@preact/signals-react/runtime'
import { useTranslation } from 'react-i18next'
import { avatarInitials } from './avatar-initials'
import { DocumentPresenceModel, peerColor } from './state/document-presence'

/**
 * The document's sync state and the people in it, at the start of the top bar's actions. Each person shows as a 24px
 * avatar with a dot in their collaboration colour; the state shows as an icon and names itself in words only while
 * the document is offline or failing, and the popover lists everyone with the state.
 */
export function DocumentPresence({
  model,
  pending,
  error
}: {
  model: InstanceType<typeof DocumentPresenceModel>
  pending: boolean
  error: boolean
}) {
  useSignals()
  const { t } = useTranslation()
  const members = model.members.value
  const status = model.connection.value
  const label =
    status === 'disconnected'
      ? 'offline'
      : error
        ? 'error'
        : status === 'connecting'
          ? 'connecting'
          : pending
            ? 'saving'
            : 'saved'
  const Icon =
    status === 'disconnected' || error
      ? CloudOffRegular
      : status === 'connecting' || pending
        ? Spinner
        : CheckmarkCircleRegular
  const statusLabel = t(`pod.collaboration.${label === 'offline' && pending ? 'offline_pending' : label}`)
  const peopleLabel = t('pod.collaboration.people', { count: members.length })
  const failing = label === 'offline' || label === 'error'
  return (
    <div
      className="flex items-center text-xs text-muted-foreground"
      data-document-presence
      role="region"
      aria-label={t('pod.collaboration.region')}>
      <Popover>
        <PopoverTrigger
          render={
            <Button
              variant="ghost"
              // The avatars are the control; the cluster shows no hover or open fill behind them.
              className="h-9 gap-2 px-1 font-normal hover:bg-transparent aria-expanded:bg-transparent"
              aria-label={peopleLabel}
              title={`${statusLabel} · ${peopleLabel}`}
            />
          }>
          <span role="status" className="flex items-center gap-1.5" data-sync-status={label}>
            <Icon aria-hidden className="size-4" />
            <span className={failing ? '@max-[860px]:sr-only' : 'sr-only'}>{statusLabel}</span>
          </span>
          <span className="flex items-center gap-1 @max-[860px]:hidden">
            {members.slice(0, 4).map(member => (
              <Avatar
                key={member.uid}
                aria-label={member.name}
                size="sm"
                title={`${member.name} · ${t(`pod.collaboration.${member.mode}`)}`}>
                {member.avatar_url && <AvatarImage src={member.avatar_url} alt="" />}
                <AvatarFallback style={{ color: peerColor(member.uid) }}>{avatarInitials(member.name)}</AvatarFallback>
                <AvatarDot style={{ color: peerColor(member.uid) }} />
              </Avatar>
            ))}
            {members.length > 4 && <span className="tabular-nums">+{members.length - 4}</span>}
          </span>
          <span className="hidden tabular-nums @max-[860px]:inline">{members.length}</span>
        </PopoverTrigger>
        <PopoverContent align="end" className="w-64">
          <p className="mb-2 text-xs text-muted-foreground">{statusLabel}</p>
          <p className="mb-2 font-medium">{peopleLabel}</p>
          {members.map(member => (
            <div key={member.uid} className="flex items-center gap-2 py-1.5 text-sm">
              <span className="size-2 shrink-0 rounded-full" style={{ backgroundColor: peerColor(member.uid) }} />
              <span className="min-w-0 flex-1 truncate">{member.name}</span>
              <span className="text-xs text-muted-foreground">{t(`pod.collaboration.${member.mode}`)}</span>
            </div>
          ))}
        </PopoverContent>
      </Popover>
    </div>
  )
}
