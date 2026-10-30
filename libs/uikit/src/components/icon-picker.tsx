'use client'

import { RiAddLine, RiUploadCloud2Line } from '@remixicon/react'
import { useEffect, useId, useRef, useState, type ClipboardEvent, type DragEvent } from 'react'
import { cn } from '../lib/utils'
import { Button } from './button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from './dialog'
import { EmojiPicker, type EmojiPickerLabels } from './emoji-picker'
import { Input } from './input'
import { Spinner } from './spinner'
import { Tabs, TabsContent, TabsList, TabsTrigger } from './tabs'

/** One picture already stored in the Pod's shared custom-picture library. */
export type IconPickerPicture = {
  id: string
  name: string
  url: string
}

export type IconPickerLabels = Omit<EmojiPickerLabels, 'reactions' | 'expandReactions'> & {
  emojiTab: string
  pictureTab: string
  remove: string
  picturesLoading: string
  picturesError: string
  picturesRetry: string
  picturesEmpty: string
  upload: string
  uploadTitle: string
  uploadDescription: string
  uploadDropzone: string
  uploadFormats: string
  uploadNameLabel: string
  uploadNamePlaceholder: string
  uploadNameHint: string
  /** Formats the stored shortcode, such as `:my_icon:`, so the field can preview it. */
  uploadNamePreview: (name: string) => string
  uploadNameInvalid: string
  uploadAdd: string
  uploadCancel: string
  uploading: string
  uploadTooLarge: string
  uploadUnsupported: string
  uploadFailed: string
}

export type IconPickerUpload = {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Called with the chosen image and its `:name:` icon name. */
  onSubmit: (file: File, name: string) => void
  pending?: boolean
  errorText?: string
}

export type IconPickerProps = {
  /** The stored icon: an emoji, a picture path, or null. */
  activeIcon?: string | null
  className?: string
  defaultTab?: 'emoji' | 'picture'
  emoji: {
    onSelect: (emoji: string) => void
    labels?: Partial<EmojiPickerLabels>
    locale?: string
  }
  /** Shows the header's Remove action when supplied. */
  onRemove?: () => void
  pictures?: {
    items: IconPickerPicture[]
    onSelect: (id: string) => void
    canUpload: boolean
    loading?: boolean
    errorText?: string
    onRetry?: () => void
    upload: IconPickerUpload
  }
  labels: IconPickerLabels
}

const MAX_PICTURE_BYTES = 1024 * 1024
const PICTURE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
/** The part between the colons of an icon name such as `:my_icon:`. */
const ICON_NAME = /^[a-z0-9_]+$/

/** Derives a bare icon name from the chosen file: "My Brain.png" → "my_brain". */
function iconNameFromFile(file: File) {
  const slug = file.name
    .replace(/\.[^.]+$/, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
  return slug || 'icon'
}

/** Accepts a bare name while editing, and wraps it in colons for saving. */
function normalizeIconName(value: string) {
  const bare = value.trim().replace(/^:+|:+$/g, '')
  return ICON_NAME.test(bare) ? `:${bare}:` : value.trim()
}

function useObjectURL(file: File | null) {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    if (!file) {
      setUrl(null)
      return
    }
    const next = URL.createObjectURL(file)
    setUrl(next)
    return () => URL.revokeObjectURL(next)
  }, [file])
  return url
}

function PictureDropzone({
  file,
  busy,
  labels,
  onFile
}: {
  file: File | null
  busy: boolean
  labels: IconPickerLabels
  onFile: (file: File) => void
}) {
  const input = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)
  const preview = useObjectURL(file)

  const accept = (candidate: File | undefined) => {
    if (candidate) onFile(candidate)
  }

  const drop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    accept(event.dataTransfer.files[0])
  }

  const paste = (event: ClipboardEvent<HTMLDivElement>) => {
    const candidate = Array.from(event.clipboardData.files)[0] ?? clipboardImage(event.clipboardData.items)
    if (candidate) {
      event.preventDefault()
      accept(candidate)
    }
  }

  return (
    <div
      className="flex min-h-[150px] items-stretch justify-stretch rounded-control border border-dashed border-border-strong bg-transparent p-3 transition-colors data-[busy=true]:opacity-60 data-[dragging=true]:border-ring data-[dragging=true]:bg-accent"
      data-busy={busy || undefined}
      data-dragging={dragging || undefined}
      onDragOver={event => {
        event.preventDefault()
        setDragging(true)
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={drop}
      onPaste={paste}>
      <input
        ref={input}
        type="file"
        accept={PICTURE_TYPES.join(',')}
        className="sr-only"
        disabled={busy}
        onChange={event => {
          accept(event.target.files?.[0])
          event.target.value = ''
        }}
      />
      {preview ? (
        <button
          type="button"
          className="flex w-full cursor-pointer flex-col items-center justify-center gap-1.5 border-0 bg-transparent text-inherit outline-none focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-2 [&_img]:size-18 [&_img]:object-contain"
          disabled={busy}
          onClick={() => input.current?.click()}>
          <img src={preview} alt="" draggable={false} />
          <span className="text-xs leading-4 text-fg-tertiary">{labels.uploadDropzone}</span>
        </button>
      ) : (
        <button
          type="button"
          className="flex w-full cursor-pointer flex-col items-center justify-center gap-1.5 border-0 bg-transparent text-inherit outline-none focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-2"
          disabled={busy}
          onClick={() => input.current?.click()}>
          <RiUploadCloud2Line aria-hidden className="size-6 text-fg-tertiary" />
          <span className="text-sm leading-5 text-foreground">{labels.uploadDropzone}</span>
          <span className="text-xs leading-4 text-fg-tertiary">{labels.uploadFormats}</span>
        </button>
      )}
    </div>
  )
}

function clipboardImage(items: DataTransferItemList): File | undefined {
  for (const item of Array.from(items)) {
    if (item.kind === 'file' && item.type.startsWith('image/')) return item.getAsFile() ?? undefined
  }
  return undefined
}

function IconUploadDialog({ labels, upload }: { labels: IconPickerLabels; upload: IconPickerUpload }) {
  const [file, setFile] = useState<File | null>(null)
  const [name, setName] = useState('')
  const [problem, setProblem] = useState<string | null>(null)
  const inputID = useId()
  const busy = Boolean(upload.pending)

  useEffect(() => {
    if (upload.open) return
    setFile(null)
    setName('')
    setProblem(null)
  }, [upload.open])

  const choose = (candidate: File) => {
    if (!PICTURE_TYPES.includes(candidate.type)) {
      setProblem(labels.uploadUnsupported)
      return
    }
    if (candidate.size > MAX_PICTURE_BYTES) {
      setProblem(labels.uploadTooLarge)
      return
    }
    setProblem(null)
    setFile(candidate)
    setName(current => (current.trim() ? current : iconNameFromFile(candidate)))
  }

  const bareName = name.trim().replace(/^:+|:+$/g, '')
  const nameValid = ICON_NAME.test(bareName)
  const nameProblem = name.trim().length > 0 && !nameValid

  const submit = () => {
    if (!file || busy || !nameValid) return
    upload.onSubmit(file, normalizeIconName(name))
  }

  return (
    <Dialog open={upload.open} onOpenChange={upload.onOpenChange}>
      <DialogContent className="sm:max-w-md" closeLabel={labels.uploadCancel}>
        <DialogHeader>
          <DialogTitle>{labels.uploadTitle}</DialogTitle>
          <DialogDescription>{labels.uploadDescription}</DialogDescription>
        </DialogHeader>
        <PictureDropzone file={file} busy={busy} labels={labels} onFile={choose} />
        <div className="flex flex-col gap-1.5">
          <label className="text-[13px] leading-5 font-medium text-foreground" htmlFor={inputID}>
            {labels.uploadNameLabel}
          </label>
          <Input
            variant="overlay"
            id={inputID}
            value={name}
            disabled={busy}
            placeholder={labels.uploadNamePlaceholder}
            autoComplete="off"
            spellCheck={false}
            aria-invalid={nameProblem || undefined}
            aria-describedby={`${inputID}-hint`}
            onChange={event => setName(event.target.value)}
            onKeyDown={event => {
              if (event.key === 'Enter') {
                event.preventDefault()
                submit()
              }
            }}
          />
          <p
            id={`${inputID}-hint`}
            className={cn('text-xs leading-4', nameProblem ? 'text-destructive-foreground' : 'text-fg-tertiary')}>
            {nameProblem
              ? labels.uploadNameInvalid
              : nameValid
                ? labels.uploadNamePreview(`:${bareName}:`)
                : labels.uploadNameHint}
          </p>
        </div>
        {(problem || upload.errorText) && (
          <p role="alert" className="text-sm leading-5 text-destructive-foreground">
            {problem ?? upload.errorText ?? labels.uploadFailed}
          </p>
        )}
        <DialogFooter>
          <Button variant="outline" disabled={busy} onClick={() => upload.onOpenChange(false)}>
            {labels.uploadCancel}
          </Button>
          <Button disabled={!file || !nameValid || busy} onClick={submit}>
            {busy && <Spinner aria-hidden className="size-4" />}
            {busy ? labels.uploading : labels.uploadAdd}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function PictureGrid({
  activeIcon,
  labels,
  pictures
}: {
  activeIcon?: string | null
  labels: IconPickerLabels
  pictures: NonNullable<IconPickerProps['pictures']>
}) {
  if (pictures.loading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 px-4 py-8 text-center text-sm leading-5 text-muted-foreground">
        <Spinner aria-hidden className="size-4" />
        <span>{labels.picturesLoading}</span>
      </div>
    )
  }
  if (pictures.errorText) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 px-4 py-8 text-center text-sm leading-5 text-muted-foreground">
        <p>{labels.picturesError}</p>
        {pictures.onRetry && (
          <Button variant="outline" size="sm" onClick={pictures.onRetry}>
            {labels.picturesRetry}
          </Button>
        )}
      </div>
    )
  }
  if (pictures.items.length === 0 && !pictures.canUpload) {
    return <p className="px-4 py-8 text-center text-sm leading-5 text-muted-foreground">{labels.picturesEmpty}</p>
  }
  return (
    <div className="grid grid-cols-[repeat(auto-fill,40px)] content-start gap-1.5 p-3">
      {pictures.items.map(picture => (
        <button
          key={picture.id}
          type="button"
          aria-label={picture.name}
          aria-pressed={activeIcon === picture.id}
          title={picture.name}
          className="inline-flex size-10 cursor-pointer items-center justify-center rounded-control border border-transparent bg-transparent text-muted-foreground transition-colors hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring focus-visible:-outline-offset-2 aria-[pressed=true]:border-ring aria-[pressed=true]:bg-accent [&_img]:size-7 [&_img]:object-contain"
          onClick={() => pictures.onSelect(picture.id)}>
          <img src={picture.url} alt="" draggable={false} />
        </button>
      ))}
      {pictures.canUpload && (
        <button
          type="button"
          className="inline-flex size-10 cursor-pointer items-center justify-center rounded-control border border-dashed border-border-strong bg-transparent text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring focus-visible:-outline-offset-2"
          aria-label={labels.upload}
          title={labels.upload}
          onClick={() => pictures.upload.onOpenChange(true)}>
          <RiAddLine aria-hidden className="size-5" />
        </button>
      )}
    </div>
  )
}

/**
 * Ankole's icon picker: an emoji tab backed by `EmojiPicker` and a picture tab
 * for the Pod's shared custom-picture library. The host owns storage and passes
 * the current picture list, upload state, and update callbacks.
 */
export function IconPicker({
  activeIcon,
  className,
  defaultTab = 'emoji',
  emoji,
  onRemove,
  pictures,
  labels
}: IconPickerProps) {
  const emojiPanel = (
    <EmojiPicker
      labels={emoji.labels}
      locale={emoji.locale}
      onEmojiSelect={emoji.onSelect}
      height="min(340px, 52dvh)"
    />
  )

  return (
    <div data-slot="icon-picker" className={cn('flex min-w-0 flex-col', className)}>
      {pictures ? (
        <Tabs defaultValue={defaultTab} className="gap-0">
          <div className="flex min-h-10 items-center justify-between gap-2 border-b border-border">
            <TabsList className="h-10 border-b-0 pl-2">
              <TabsTrigger value="emoji">{labels.emojiTab}</TabsTrigger>
              <TabsTrigger value="picture">{labels.pictureTab}</TabsTrigger>
            </TabsList>
            {onRemove && (
              <Button variant="ghost" size="sm" className="mr-1.5" onClick={onRemove}>
                {labels.remove}
              </Button>
            )}
          </div>
          <TabsContent value="emoji">{emojiPanel}</TabsContent>
          <TabsContent value="picture" className="h-[min(340px,52dvh)] flex-none overflow-y-auto overscroll-contain">
            <PictureGrid activeIcon={activeIcon} labels={labels} pictures={pictures} />
          </TabsContent>
        </Tabs>
      ) : (
        <>
          {onRemove && (
            <div className="flex min-h-10 items-center justify-end border-b border-border">
              <Button variant="ghost" size="sm" className="mr-1.5" onClick={onRemove}>
                {labels.remove}
              </Button>
            </div>
          )}
          {emojiPanel}
        </>
      )}
      {pictures && <IconUploadDialog labels={labels} upload={pictures.upload} />}
    </div>
  )
}
