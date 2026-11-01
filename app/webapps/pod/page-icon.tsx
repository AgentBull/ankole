import { usePageMetadata } from './use-page-metadata'
import {
  RiFolderLine,
  RiApps2Line,
  RiAttachment2,
  RiDatabase2Line,
  RiEmotionLine,
  RiFileTextLine
} from '@remixicon/react'
import {
  Button,
  IconPicker,
  Popover,
  PopoverContent,
  PopoverTrigger,
  cn,
  type EmojiPickerLabels,
  type IconPickerLabels
} from '@ankole/uikit'
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { t } from 'i18next'
import { useTranslation } from 'react-i18next'
import { contentKeys, metadataFileURL, pageAPI, type Page } from './content-api'
import { ContentError } from './content-primitives'
import { isCustomEmojiIcon } from './page-icon-value'
import { customEmojiLibrary, uploadCustomEmoji } from './native-transfers'
import { InternalAPIError } from '../common/internal-api-client'
import { updatePageMetadata } from './state/navigation-cache'

const icons = {
  folder: RiFolderLine,
  doc: RiFileTextLine,
  base: RiDatabase2Line,
  applet: RiApps2Line,
  file: RiAttachment2
}

/** A Page keeps the same type mark in navigation, references, and pickers. */
export function PageIcon({ page, className }: { page: Pick<Page, 'type' | 'icon'>; className?: string }) {
  const classes = cn('pod-page-icon', className)
  // A custom emoji whose file fails to load falls back to the Page's type mark.
  const [failedIcon, setFailedIcon] = useState<string | null>(null)
  if (isCustomEmojiIcon(page.icon) && failedIcon !== page.icon) {
    const icon = page.icon
    return (
      <img
        src={metadataFileURL(icon)}
        alt=""
        draggable={false}
        className={cn(classes, 'object-contain')}
        onError={() => setFailedIcon(icon)}
      />
    )
  }
  if (page.icon && !isCustomEmojiIcon(page.icon)) {
    return (
      <span aria-hidden className={cn(classes, 'ankole-fluent-emoji')}>
        {page.icon}
      </span>
    )
  }
  const Icon = icons[page.type]
  return <Icon aria-hidden className={classes} />
}

function emojiPickerLabels(): Partial<EmojiPickerLabels> {
  return {
    searchPlaceholder: t('pod.content.emoji_search'),
    searchLabel: t('pod.content.emoji_search'),
    searchClear: t('pod.content.emoji_search_clear'),
    searchResultsNone: t('pod.content.emoji_no_results'),
    searchResultsOne: t('pod.content.emoji_one_result'),
    searchResultsMany: t('pod.content.emoji_results'),
    categoryNavigation: t('pod.content.emoji_categories'),
    loading: t('pod.content.emoji_loading'),
    loadingError: t('pod.content.emoji_loading_error'),
    retryLoading: t('pod.content.emoji_retry'),
    skinToneNeutral: t('pod.content.emoji_skin_tone_neutral'),
    skinToneLight: t('pod.content.emoji_skin_tone_light'),
    skinToneMediumLight: t('pod.content.emoji_skin_tone_medium_light'),
    skinToneMedium: t('pod.content.emoji_skin_tone_medium'),
    skinToneMediumDark: t('pod.content.emoji_skin_tone_medium_dark'),
    skinToneDark: t('pod.content.emoji_skin_tone_dark')
  }
}

function iconPickerLabels(): IconPickerLabels {
  return {
    ...emojiPickerLabels(),
    emojiTab: t('pod.content.icon_tab_emoji'),
    pictureTab: t('pod.content.icon_tab_picture'),
    remove: t('pod.content.remove_icon'),
    picturesLoading: t('pod.content.custom_emoji_loading'),
    picturesError: t('pod.content.custom_emoji_load_error'),
    picturesRetry: t('pod.content.custom_emoji_retry'),
    picturesEmpty: t('pod.content.custom_emoji_empty'),
    upload: t('pod.content.custom_emoji_upload'),
    uploadTitle: t('pod.content.custom_emoji_upload_title'),
    uploadDescription: t('pod.content.custom_emoji_upload_description'),
    uploadDropzone: t('pod.content.custom_emoji_dropzone'),
    uploadFormats: t('pod.content.custom_emoji_formats'),
    uploadNameLabel: t('pod.content.custom_emoji_name_label'),
    uploadNamePlaceholder: t('pod.content.custom_emoji_name_placeholder'),
    uploadNameHint: t('pod.content.custom_emoji_name_hint'),
    uploadNamePreview: name => t('pod.content.custom_emoji_name_preview', { name }),
    uploadNameInvalid: t('pod.content.custom_emoji_name_invalid'),
    uploadAdd: t('pod.content.custom_emoji_add'),
    uploadCancel: t('pod.content.custom_emoji_cancel'),
    uploading: t('pod.content.custom_emoji_uploading'),
    uploadTooLarge: t('pod.content.custom_emoji_too_large'),
    uploadUnsupported: t('pod.content.custom_emoji_unsupported'),
    uploadFailed: t('pod.content.custom_emoji_failed')
  } as IconPickerLabels
}

const MAX_ICON_EDGE = 128

/**
 * Resizes a picked picture to an icon-sized image while keeping transparency.
 * GIFs keep their bytes and animation; the upload dialog already caps them at
 * one megabyte.
 */
async function prepareIconPicture(file: File, name: string): Promise<File> {
  const stem = name.replace(/\.[^.]+$/, '').trim() || 'icon'
  if (file.type === 'image/gif') return new File([file], `${stem}.gif`, { type: file.type })

  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, MAX_ICON_EDGE / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(bitmap.width * scale))
  canvas.height = Math.max(1, Math.round(bitmap.height * scale))
  const context = canvas.getContext('2d')
  if (!context) {
    bitmap.close()
    throw new Error(t('pod.content.custom_emoji_failed'))
  }
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()

  const type = file.type === 'image/jpeg' ? 'image/jpeg' : 'image/png'
  const extension = type === 'image/jpeg' ? '.jpg' : '.png'
  const blob = await new Promise<Blob | null>(resolve => canvas.toBlob(resolve, type, 0.9))
  if (!blob) throw new Error(t('pod.content.custom_emoji_failed'))
  return new File([blob], `${stem}${extension}`, { type })
}

/** Page metadata owns the icon, including every navigation and reference rendering. */
export function PageIconPicker({ page: sourcePage, editable }: { page: Page; editable: boolean }) {
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const [open, setOpen] = useState(false)
  const [uploadOpen, setUploadOpen] = useState(false)

  const page = usePageMetadata(sourcePage)
  const update = useMutation({
    scope: { id: `page-icon:${page.id}` },
    mutationFn: (icon: string | null) => pageAPI.update(page.id, { icon }),
    onSuccess: ({ page }) => {
      updatePageMetadata(client, { id: page.id, icon: page.icon })
      setOpen(false)
    }
  })

  const library = useQuery({
    queryKey: contentKeys.customEmojis(),
    queryFn: ({ signal }) => customEmojiLibrary(signal),
    enabled: open
  })

  const upload = useMutation({
    scope: { id: `page-icon-picture:${page.id}` },
    mutationFn: async ({ file, name }: { file: File; name: string }) => {
      const picture = await prepareIconPicture(file, name.slice(1, -1))
      const customEmoji = await uploadCustomEmoji(picture, name)
      return pageAPI.update(page.id, { icon: customEmoji.path })
    },
    onSuccess: ({ page }) => {
      updatePageMetadata(client, { id: page.id, icon: page.icon })
      setUploadOpen(false)
      setOpen(false)
    }
  })

  const busy = update.isPending || upload.isPending

  if (!editable) return page.icon ? <PageIcon page={page} className="pod-page-title-icon" /> : null

  const uploadError = upload.isError
    ? upload.error instanceof InternalAPIError && upload.error.status === 413
      ? t('pod.content.custom_emoji_too_large')
      : t('pod.content.custom_emoji_failed')
    : undefined

  return (
    <Popover
      open={open}
      onOpenChange={next => {
        if (busy) return
        setOpen(next)
        if (next) {
          update.reset()
          upload.reset()
        } else {
          setUploadOpen(false)
        }
      }}>
      <PopoverTrigger
        render={
          <Button
            variant="ghost"
            className={page.icon ? 'pod-page-title-icon' : 'pod-page-add-icon'}
            aria-label={t(page.icon ? 'pod.content.change_icon' : 'pod.content.add_icon')}>
            {page.icon ? (
              <PageIcon page={page} />
            ) : (
              <>
                <RiEmotionLine aria-hidden />
                {t('pod.content.add_icon')}
              </>
            )}
          </Button>
        }
      />
      <PopoverContent
        align="start"
        aria-busy={busy}
        aria-label={t('pod.content.page_icon')}
        className="pod-icon-picker">
        <IconPicker
          activeIcon={page.icon}
          emoji={{
            labels: emojiPickerLabels(),
            locale: i18n.language,
            onSelect: emoji => {
              if (!busy) update.mutate(emoji)
            }
          }}
          defaultTab={isCustomEmojiIcon(page.icon) ? 'picture' : 'emoji'}
          labels={iconPickerLabels()}
          onRemove={page.icon && !busy ? () => update.mutate(null) : undefined}
          pictures={{
            items: (library.data?.custom_emojis ?? []).map(picture => ({
              id: picture.path,
              name: picture.name,
              url: metadataFileURL(picture.path)
            })),
            loading: library.isPending,
            errorText: library.isError ? t('pod.content.custom_emoji_load_error') : undefined,
            onRetry: () => void library.refetch(),
            canUpload: library.data?.can_upload ?? false,
            onSelect: picture => {
              if (!busy) update.mutate(picture)
            },
            upload: {
              open: uploadOpen,
              onOpenChange: next => {
                setUploadOpen(next)
                if (!next) upload.reset()
              },
              pending: upload.isPending,
              errorText: uploadError,
              onSubmit: (file, name) => upload.mutate({ file, name })
            }
          }}
        />
        {update.isError && (
          <div className="px-3 pb-3">
            <ContentError error={update.error} retry={() => update.mutate(update.variables)} />
          </div>
        )}
      </PopoverContent>
    </Popover>
  )
}
