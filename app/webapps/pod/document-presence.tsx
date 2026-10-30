import { Avatar, AvatarFallback, AvatarImage, Button, Popover, PopoverContent, PopoverTrigger } from '@ankole/uikit'
import { RiCheckboxCircleLine, RiCloudOffLine, RiLoader4Line } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useTranslation } from 'react-i18next'
import { avatarInitials } from './avatar-initials'
import { DocumentPresenceModel, peerColor } from './state/document-presence'

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
      ? RiCloudOffLine
      : status === 'connecting' || pending
        ? RiLoader4Line
        : RiCheckboxCircleLine
  const statusLabel = t(`pod.collaboration.${label === 'offline' && pending ? 'offline_pending' : label}`)
  const peopleLabel = t('pod.collaboration.people', { count: members.length })
  return (
    <div
      className="flex items-center gap-1 text-xs text-muted-foreground"
      data-document-presence
      role="region"
      aria-label={t('pod.collaboration.region')}>
      <Popover>
        <PopoverTrigger
          render={<Button variant="ghost" size="sm" className="gap-1 @max-[860px]:px-1" aria-label={peopleLabel} />}>
          <span role="status" className="flex items-center gap-1.5" data-sync-status={label}>
            <Icon aria-hidden className="size-3.5" />
            <span className="@max-[860px]:sr-only">{statusLabel}</span>
          </span>
          <span className="flex -space-x-1.5 @max-[860px]:hidden">
            {members.slice(0, 4).map(member => (
              <Avatar
                key={member.uid}
                aria-label={member.name}
                size="sm"
                className="ring-2 ring-background"
                title={`${member.name} · ${t(`pod.collaboration.${member.mode}`)}`}>
                {member.avatar_url && <AvatarImage src={member.avatar_url} alt="" />}
                <AvatarFallback style={{ color: peerColor(member.uid) }}>{avatarInitials(member.name)}</AvatarFallback>
              </Avatar>
            ))}
          </span>
          <span className="@max-[860px]:hidden">{members.length > 4 ? `+${members.length - 4}` : peopleLabel}</span>
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
