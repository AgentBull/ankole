import { Avatar, AvatarFallback, AvatarImage, Button, cn, toast } from '@ankole/uikit'
import { RiCameraLine } from '@remixicon/react'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ContentError } from './content-primitives'
import { avatarInitials } from './avatar-initials'
import { currentProfileAvatarContext, profileAvatarURL, uploadProfileAvatar } from './native-transfers'

const acceptedTypes = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp'])
const maxAvatarBytes = 5 * 1024 * 1024

export function ProfileAvatarUpload({
  kind,
  name,
  avatarURL,
  onUploaded
}: {
  kind: 'member' | 'space'
  name: string
  avatarURL?: string | null
  onUploaded(avatarURL: string): void
}) {
  const { t } = useTranslation()
  const input = useRef<HTMLInputElement>(null)
  const mountedRef = useRef(true)
  const [preview, setPreview] = useState<string>()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<unknown>()

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    if (!preview) return
    return () => URL.revokeObjectURL(preview)
  }, [preview])

  const select = async (file: File | undefined) => {
    if (!file || pending) return
    if (!acceptedTypes.has(file.type)) {
      setError(new Error(t('pod.settings.avatar_unsupported')))
      return
    }
    if (file.size > maxAvatarBytes) {
      setError(new Error(t('pod.settings.avatar_too_large')))
      return
    }

    setError(undefined)
    setPending(true)
    setPreview(URL.createObjectURL(file))
    try {
      const result = await uploadProfileAvatar(kind, file)
      onUploaded(result.avatarURL)
      const nextSource = profileAvatarURL(result.avatarURL, currentProfileAvatarContext())
      if (nextSource && typeof Image !== 'undefined') {
        const preloaded = new Image()
        preloaded.src = nextSource
        await preloaded.decode().catch(() => undefined)
      }
      if (mountedRef.current) {
        setPreview(undefined)
        toast.success(t('pod.settings.avatar_updated'))
      }
    } catch (uploadError) {
      if (mountedRef.current) {
        setPreview(undefined)
        setError(uploadError)
      }
    } finally {
      if (mountedRef.current) {
        setPending(false)
      }
    }
  }

  const source = preview ?? profileAvatarURL(avatarURL, currentProfileAvatarContext())
  const square = kind === 'space'
  return (
    <div className="grid gap-4">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
        <Avatar
          className={cn(
            'size-20 bg-muted ring-1 ring-border',
            square ? 'rounded-2xl after:rounded-2xl' : 'rounded-full',
            pending && 'opacity-70'
          )}>
          {source && (
            <AvatarImage
              src={source}
              alt={t('pod.settings.avatar_alt', { name })}
              className={cn(square ? 'rounded-2xl' : 'rounded-full')}
            />
          )}
          <AvatarFallback className={cn('text-xl font-medium', square ? 'rounded-2xl' : 'rounded-full')}>
            {avatarInitials(name)}
          </AvatarFallback>
        </Avatar>
        <div className="grid min-w-0 gap-2">
          <div className="grid gap-1">
            <p className="text-sm font-medium text-foreground">{t('pod.settings.avatar')}</p>
            <p id={`${kind}-avatar-hint`} className="text-xs leading-5 text-muted-foreground">
              {t('pod.settings.avatar_hint')}
            </p>
          </div>
          <div>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={pending}
              aria-describedby={`${kind}-avatar-hint`}
              onClick={() => input.current?.click()}>
              <RiCameraLine aria-hidden data-icon="inline-start" />
              {pending ? t('pod.settings.avatar_uploading') : t('pod.settings.avatar_change')}
            </Button>
          </div>
        </div>
      </div>
      <input
        ref={input}
        type="file"
        hidden
        accept="image/png,image/jpeg,image/gif,image/webp"
        aria-label={t('pod.settings.avatar_change')}
        onChange={event => {
          const file = event.target.files?.[0]
          event.target.value = ''
          void select(file)
        }}
      />
      <ContentError error={error} />
    </div>
  )
}
