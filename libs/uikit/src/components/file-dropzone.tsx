'use client'

import { RiCloseLine, RiFileTextLine, RiUploadCloud2Line } from '@remixicon/react'
import * as React from 'react'

import { cn } from '../lib/utils'
import { Button } from './button'

export type FileRejectionReason = 'file_too_large' | 'invalid_type' | 'too_many_files'

export type FileRejection = {
  file: Pick<File, 'name' | 'size' | 'type'>
  reason: FileRejectionReason
}

export type FileDropzoneProps = {
  accept?: string
  multiple?: boolean
  maxFiles?: number
  maxSizeBytes?: number
  disabled?: boolean
  files?: readonly File[]
  onFilesSelected?: (files: File[]) => void
  onFilesRejected?: (rejections: FileRejection[]) => void
  onRemoveFile?: (index: number) => void
  label?: React.ReactNode
  description?: React.ReactNode
  browseLabel?: string
  removeFileLabel?: (fileName: string) => string
  errorMessage?: React.ReactNode
  className?: string
}

export function formatFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function matchesAcceptSpec(file: Pick<File, 'name' | 'type'>, accept?: string): boolean {
  if (!accept || !accept.trim()) return true
  const tokens = accept
    .split(',')
    .map(token => token.trim().toLowerCase())
    .filter(Boolean)
  if (tokens.length === 0) return true
  const mime = (file.type || '').toLowerCase()
  const lowerName = file.name.toLowerCase()
  return tokens.some(token => {
    if (token.startsWith('.')) return lowerName.endsWith(token)
    if (token.endsWith('/*')) {
      const prefix = token.slice(0, -1)
      return mime.startsWith(prefix)
    }
    return mime === token
  })
}

export function partitionDroppedFiles<T extends Pick<File, 'name' | 'size' | 'type'>>(
  incoming: readonly T[],
  options: {
    accept?: string
    multiple?: boolean
    maxSizeBytes?: number
    maxFiles?: number
    existingCount?: number
  } = {}
): { accepted: T[]; rejected: { file: T; reason: FileRejectionReason }[] } {
  const accepted: T[] = []
  const rejected: { file: T; reason: FileRejectionReason }[] = []
  const existingCount = options.existingCount ?? 0
  const effectiveMaxFiles = options.maxFiles ?? (options.multiple === false ? 1 : undefined)

  for (const file of incoming) {
    if (!matchesAcceptSpec(file, options.accept)) {
      rejected.push({ file, reason: 'invalid_type' })
      continue
    }
    if (options.maxSizeBytes !== undefined && file.size > options.maxSizeBytes) {
      rejected.push({ file, reason: 'file_too_large' })
      continue
    }
    if (effectiveMaxFiles !== undefined && existingCount + accepted.length >= effectiveMaxFiles) {
      rejected.push({ file, reason: 'too_many_files' })
      continue
    }
    accepted.push(file)
  }

  return { accepted, rejected }
}

function defaultRejectionSummary(
  rejections: readonly FileRejection[],
  maxSizeBytes?: number,
  maxFiles?: number
): string {
  const first = rejections[0]
  if (!first) return ''
  switch (first.reason) {
    case 'file_too_large':
      return `${first.file.name} exceeds ${maxSizeBytes ? formatFileSize(maxSizeBytes) : 'the size limit'}.`
    case 'invalid_type':
      return `${first.file.name} does not match the accepted file format.`
    case 'too_many_files':
      return maxFiles ? `Select up to ${maxFiles} file${maxFiles === 1 ? '' : 's'}.` : 'Too many files selected.'
  }
}

export function FileDropzone({
  accept,
  multiple,
  maxFiles,
  maxSizeBytes,
  disabled = false,
  files,
  onFilesSelected,
  onFilesRejected,
  onRemoveFile,
  label = 'Drop files here or browse',
  description,
  browseLabel = 'Choose files',
  removeFileLabel = name => `Remove ${name}`,
  errorMessage,
  className
}: FileDropzoneProps) {
  const inputRef = React.useRef<HTMLInputElement>(null)
  const descriptionId = React.useId()
  const errorId = React.useId()
  const dragDepth = React.useRef(0)
  const [dragActive, setDragActive] = React.useState(false)
  const [rejections, setRejections] = React.useState<FileRejection[]>([])
  const allowMultiple = multiple ?? (maxFiles === undefined || maxFiles > 1)
  const effectiveMaxFiles = maxFiles ?? (allowMultiple ? undefined : 1)

  const handleFiles = (fileList: FileList | null) => {
    if (disabled || !fileList || fileList.length === 0) return
    const list = Array.from(fileList)
    const { accepted, rejected } = partitionDroppedFiles(list, {
      accept,
      multiple: allowMultiple,
      maxSizeBytes,
      maxFiles: effectiveMaxFiles,
      existingCount: allowMultiple ? (files?.length ?? 0) : 0
    })
    setRejections(rejected)
    if (rejected.length > 0) onFilesRejected?.(rejected)
    if (accepted.length > 0) onFilesSelected?.(accepted)
  }

  const resolvedError =
    errorMessage ??
    (rejections.length > 0 ? defaultRejectionSummary(rejections, maxSizeBytes, effectiveMaxFiles) : null)
  const describedBy = [description != null ? descriptionId : null, resolvedError ? errorId : null]
    .filter(Boolean)
    .join(' ')

  return (
    <div data-slot="file-dropzone" className={cn('grid gap-2', className)}>
      <div
        onDragEnter={event => {
          event.preventDefault()
          event.stopPropagation()
          if (disabled) return
          dragDepth.current += 1
          setDragActive(true)
        }}
        onDragOver={event => {
          event.preventDefault()
          event.stopPropagation()
          if (!disabled) event.dataTransfer.dropEffect = 'copy'
        }}
        onDragLeave={event => {
          event.preventDefault()
          event.stopPropagation()
          dragDepth.current = Math.max(0, dragDepth.current - 1)
          if (dragDepth.current === 0) setDragActive(false)
        }}
        onDrop={event => {
          event.preventDefault()
          event.stopPropagation()
          dragDepth.current = 0
          setDragActive(false)
          handleFiles(event.dataTransfer.files)
        }}
        data-drag-active={dragActive ? '' : undefined}
        data-disabled={disabled ? '' : undefined}
        className={cn(
          'relative flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border bg-field/50 px-4 py-5 text-center transition-colors',
          dragActive && 'border-primary bg-accent/50',
          disabled && 'opacity-55'
        )}>
        <input
          ref={inputRef}
          type="file"
          accept={accept}
          multiple={allowMultiple}
          disabled={disabled}
          aria-invalid={resolvedError != null ? true : undefined}
          aria-describedby={describedBy || undefined}
          onChange={event => {
            handleFiles(event.currentTarget.files)
            event.currentTarget.value = ''
          }}
          className="sr-only"
          tabIndex={-1}
        />
        <RiUploadCloud2Line aria-hidden="true" className="size-6 text-muted-foreground" />
        <div className="grid gap-0.5">
          <p className="text-sm font-medium text-foreground">{label}</p>
          {description != null && (
            <p id={descriptionId} className="text-xs text-muted-foreground">
              {description}
            </p>
          )}
        </div>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={disabled}
          aria-describedby={describedBy || undefined}
          onClick={() => inputRef.current?.click()}>
          {browseLabel}
        </Button>
      </div>

      {resolvedError != null && (
        <p id={errorId} role="alert" className="text-xs text-destructive">
          {resolvedError}
        </p>
      )}

      {files && files.length > 0 && (
        <ul data-slot="file-dropzone-list" className="grid gap-1.5">
          {files.map((file, index) => (
            <li
              key={`${file.name}:${file.size}:${index}`}
              className="flex items-center justify-between gap-2 rounded-control border border-border bg-background px-2.5 py-1.5 text-xs">
              <span className="flex min-w-0 items-center gap-2">
                <RiFileTextLine aria-hidden="true" className="size-4 shrink-0 text-muted-foreground" />
                <span className="truncate font-medium text-foreground">{file.name}</span>
                <span className="shrink-0 text-muted-foreground tabular-nums">{formatFileSize(file.size)}</span>
              </span>
              {onRemoveFile && !disabled && (
                <Button
                  type="button"
                  size="icon-xs"
                  variant="ghost"
                  aria-label={removeFileLabel(file.name)}
                  onClick={() => onRemoveFile(index)}>
                  <RiCloseLine aria-hidden="true" className="size-3.5" />
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
