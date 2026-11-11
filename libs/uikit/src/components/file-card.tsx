import type { ComponentProps, MouseEvent, ReactNode, Ref } from 'react'

import {
  DocumentImageRegular,
  DocumentMarkdownRegular,
  DocumentPdfRegular,
  DocumentPowerpointRegular,
  DocumentRegular,
  DocumentTableRegular,
  DocumentTextRegular,
  DocumentWordRegular,
  FolderZipRegular,
  MusicNote2Regular,
  VideoRegular,
  type IconComponent,
  type IconProps
} from '../icons'
import { cn } from '../lib/utils'

const extensionKinds: Record<string, FileKind> = {}
for (const [kind, extensions] of Object.entries({
  pdf: 'pdf',
  word: 'doc docx odt rtf pages',
  table: 'xls xlsx xlsm xlsb ods numbers csv tsv',
  slides: 'ppt pptx odp key',
  markdown: 'md markdown mdx',
  text: 'txt log json jsonl yaml yml xml html htm css js jsx mjs ts tsx py rb go rs java kt swift c cc cpp h hpp sh sql toml ini',
  image: 'png jpg jpeg gif webp svg bmp heic heif avif tif tiff ico',
  video: 'mp4 mov m4v webm avi mkv',
  audio: 'mp3 m4a wav aac flac ogg oga opus',
  archive: 'zip rar 7z tar gz tgz bz2 xz'
} satisfies Record<FileKind, string>)) {
  for (const extension of extensions.split(' ')) extensionKinds[extension] = kind as FileKind
}

type FileKind = 'pdf' | 'word' | 'table' | 'slides' | 'markdown' | 'text' | 'image' | 'video' | 'audio' | 'archive'

const kindIcons: Record<FileKind | 'file', IconComponent> = {
  pdf: DocumentPdfRegular,
  word: DocumentWordRegular,
  table: DocumentTableRegular,
  slides: DocumentPowerpointRegular,
  markdown: DocumentMarkdownRegular,
  text: DocumentTextRegular,
  image: DocumentImageRegular,
  video: VideoRegular,
  audio: MusicNote2Regular,
  archive: FolderZipRegular,
  file: DocumentRegular
}

/**
 * The kind of file a name and a media type describe. The extension decides first, because uploads and external
 * channels often send a generic media type; the media type decides when the name has no known extension.
 */
export function fileTypeKind(name?: string | null, type?: string | null): FileKind | 'file' {
  const dot = name?.lastIndexOf('.') ?? -1
  const extension = name && dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
  const byName = extensionKinds[extension]
  if (byName) return byName
  const mime = type?.toLowerCase() ?? ''
  if (mime === 'application/pdf') return 'pdf'
  if (mime.startsWith('image/')) return 'image'
  if (mime.startsWith('video/')) return 'video'
  if (mime.startsWith('audio/')) return 'audio'
  if (mime === 'text/markdown') return 'markdown'
  if (mime.startsWith('text/')) return 'text'
  return 'file'
}

/**
 * The mark of a file's type: an outlined document in the secondary colour that names the kind of file, 20px by
 * default. A file whose kind Ankole does not know takes the plain document.
 */
function FileTypeMark({
  fileName,
  mimeType,
  className,
  ...props
}: IconProps & { fileName?: string | null; mimeType?: string | null }) {
  const kind = fileTypeKind(fileName, mimeType)
  const Icon = kindIcons[kind]
  return (
    <Icon
      aria-hidden
      data-slot="file-type-mark"
      data-kind={kind}
      className={cn('size-5 shrink-0 text-fg-secondary', className)}
      {...props}
    />
  )
}

type FileCardProps = Omit<ComponentProps<'div'>, 'children'> & {
  /** The mark at the start: a 20px `FileTypeMark`, or an image's 24px thumbnail. */
  mark: ReactNode
  /** The file's name, on one line. A string gives way at its end; a caller that truncates elsewhere passes nodes. */
  name: ReactNode
  /** The meta after the name: the file's type and size, or the state of its upload. */
  description?: ReactNode
  /** The controls at the end, such as a download or a draft's remove button, each a 24px button with a 16px icon. */
  action?: ReactNode
  /** How much of an upload has arrived, from 0 to 1. A bar along the bottom edge shows it. */
  progress?: number
  /** A file that failed: its line and its bar take the destructive colour. */
  invalid?: boolean
  /** Opens the file. The card's mark and name then form one control, and the whole card takes its pointer. */
  onOpen?: (event: MouseEvent<HTMLButtonElement>) => void
  /** The accessible name of the open control. */
  openLabel?: string
  /** The tooltip of the open control, such as the full file name. */
  openTitle?: string
  openRef?: Ref<HTMLButtonElement>
}

/**
 * A file that a person opens or takes away, in content or in a draft: an outline card of one 40px row, at most
 * 290px wide, that shrinks with its column. A 20px type mark in the secondary colour, the name in the 14px Medium
 * step, the type and size in the 12px tertiary step after it on the name's baseline, and the card's controls at
 * the end.
 *
 * With `onOpen`, the mark and the text are one button, and its hit area and hover wash stretch over the whole
 * card under the end controls, which keep their own.
 */
function FileCard({
  mark,
  name,
  description,
  action,
  progress,
  invalid = false,
  onOpen,
  openLabel,
  openTitle,
  openRef,
  className,
  ...props
}: FileCardProps) {
  const body = (
    <>
      <span
        data-slot="file-card-mark"
        className="flex size-5 shrink-0 items-center justify-center overflow-hidden rounded-mini has-[>img]:size-6 [&>img]:size-full [&>img]:object-cover">
        {mark}
      </span>
      <span className="flex min-w-0 flex-1 items-baseline gap-2 text-start">
        <span
          data-slot="file-card-name"
          className="flex min-w-0 flex-1 items-center gap-1 overflow-hidden text-75 font-medium whitespace-nowrap text-foreground">
          {typeof name === 'string' ? <span className="min-w-0 truncate">{name}</span> : name}
        </span>
        {description != null && (
          <span
            data-slot="file-card-description"
            className={cn(
              'max-w-[45%] shrink-0 truncate text-50 font-normal tabular-nums',
              invalid ? 'text-destructive-foreground' : 'text-fg-tertiary'
            )}>
            {description}
          </span>
        )}
      </span>
    </>
  )
  return (
    <div
      data-slot="file-card"
      data-invalid={invalid || undefined}
      className={cn(
        'surface-outline relative isolate flex h-10 w-72.5 max-w-full min-w-0 items-center gap-2 py-0',
        className
      )}
      {...props}>
      {onOpen ? (
        <button
          ref={openRef}
          type="button"
          data-slot="file-card-open"
          aria-label={openLabel}
          title={openTitle}
          onClick={onOpen}
          className="flex min-w-0 flex-1 cursor-pointer items-center gap-2 outline-none after:absolute after:inset-0 after:-z-10 after:rounded-[calc(var(--radius-surface)-1px)] after:transition-colors after:duration-(--duration-feedback) hover:after:bg-layer-hover active:after:bg-layer-pressed focus-visible:after:outline-2 focus-visible:after:outline-offset-2 focus-visible:after:outline-ring focus-visible:after:outline-solid">
          {body}
        </button>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-2">{body}</div>
      )}
      {action != null && (
        <div data-slot="file-card-action" className="flex shrink-0 items-center gap-1">
          {action}
        </div>
      )}
      {progress !== undefined && (
        <span
          aria-hidden
          className="pointer-events-none absolute inset-0 overflow-hidden rounded-[calc(var(--radius-surface)-1px)]">
          <span className="absolute inset-x-0 bottom-0 h-0.5 bg-layer-03">
            <span
              className={cn(
                'block h-full origin-left motion-safe:transition-[scale] motion-safe:duration-200 motion-safe:ease-[cubic-bezier(.22,1,.36,1)]',
                invalid ? 'bg-destructive' : 'bg-info'
              )}
              style={{ scale: `${Math.min(1, Math.max(0, progress))} 1` }}
            />
          </span>
        </span>
      )}
    </div>
  )
}

/**
 * Lays file cards out in rows 8px apart: three 290px cards in the 892px content column, fewer in a narrower one,
 * and a card shrinks with a column narrower than itself.
 */
function FileCardList({ className, ...props }: ComponentProps<'ul'>) {
  return (
    <ul
      data-slot="file-card-list"
      className={cn('flex flex-wrap gap-2 *:max-w-full *:min-w-0', className)}
      {...props}
    />
  )
}

export { FileCard, FileCardList, FileTypeMark }
