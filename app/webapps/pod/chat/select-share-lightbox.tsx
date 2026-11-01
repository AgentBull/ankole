import { Button, Dialog, DialogContent, DialogFooter, DialogTitle, toast } from '@ankole/uikit'
import { RiAlertLine, RiCheckLine, RiDownloadLine, RiFileCopyLine, RiImageLine, RiSaveLine } from '@remixicon/react'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConversationMessage } from '../api'
import { downloadMarkdownString, selectionToMarkdown } from './export-markdown'
import type { CaptureSelectedMessagesResult } from './select-screenshot'

export function SelectShareLightbox({
  open,
  onOpenChange,
  loading,
  error,
  result,
  messages,
  title,
  onSaveAsPage
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  loading: boolean
  error?: string | null
  result: CaptureSelectedMessagesResult | null
  messages: ConversationMessage[]
  title?: string
  onSaveAsPage?: () => void
}) {
  const { t } = useTranslation()
  const [copiedKind, setCopiedKind] = useState<'image' | 'markdown' | null>(null)
  const copyTimer = useRef<ReturnType<typeof setTimeout>>(undefined)

  useEffect(() => () => clearTimeout(copyTimer.current), [])

  const markCopied = (kind: 'image' | 'markdown') => {
    setCopiedKind(kind)
    clearTimeout(copyTimer.current)
    copyTimer.current = setTimeout(() => setCopiedKind(null), 1500)
  }

  const markdown = selectionToMarkdown(messages, { title })
  const filenameBase = title?.trim() || 'conversation-excerpt'

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="pod-dialog max-w-2xl" closeLabel={t('common.close')}>
        <DialogTitle>
          {t('pod.chat_timeline.share_selection_title', { defaultValue: 'Share selected messages' })}
        </DialogTitle>

        {loading && (
          <div
            role="status"
            className="flex min-h-40 items-center justify-center rounded border border-border bg-layer-01 p-6 text-sm text-fg-secondary">
            {t('pod.chat_timeline.generating_share_card', { defaultValue: 'Generating share image…' })}
          </div>
        )}

        {!loading && error && (
          <div
            role="alert"
            className="flex items-start gap-2 rounded border border-border bg-layer-01 p-4 text-sm text-fg-secondary">
            <RiAlertLine className="mt-0.5 size-4 shrink-0 text-status-warning" aria-hidden />
            <span>{error}</span>
          </div>
        )}

        {!loading && !error && result?.kind === 'needsPagination' && (
          <div
            role="status"
            data-testid="share-card-needs-pagination"
            className="flex flex-col gap-2 rounded border border-border bg-layer-01 p-4 text-sm text-fg-primary">
            <div className="flex items-start gap-2 font-medium">
              <RiAlertLine className="mt-0.5 size-4 shrink-0 text-status-warning" aria-hidden />
              <span>
                {t('pod.chat_timeline.share_card_too_tall_title', {
                  defaultValue: 'Selected excerpt exceeds single-image canvas limits'
                })}
              </span>
            </div>
            <p className="text-xs text-fg-secondary">
              {t('pod.chat_timeline.share_card_too_tall_hint', {
                defaultValue:
                  'At {$width}×{$height} px, rasterizing a single PNG would exceed browser canvas limits. Select fewer messages for an image card, or export the full excerpt as Markdown or a Pod document below.',
                width: result.cssWidth,
                height: result.cssHeight
              })}
            </p>
          </div>
        )}

        {!loading && !error && result?.kind === 'ok' && (
          <div className="max-h-[60vh] overflow-auto rounded border border-border bg-layer-01 p-3">
            <img
              src={result.dataUrl}
              alt={t('pod.chat_timeline.share_selection_title', { defaultValue: 'Share selected messages' })}
              className="mx-auto block h-auto max-w-full rounded shadow-xs"
            />
          </div>
        )}

        <DialogFooter className="flex flex-wrap items-center justify-end gap-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(markdown)
                markCopied('markdown')
                toast.success(t('pod.chat_timeline.copied'))
              } catch {
                toast.error(t('pod.chat.copy_failed'))
              }
            }}>
            {copiedKind === 'markdown' ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
            {t('pod.chat_timeline.copy_markdown', { defaultValue: 'Copy Markdown' })}
          </Button>
          <Button variant="ghost" size="sm" onClick={() => downloadMarkdownString(markdown, filenameBase)}>
            <RiDownloadLine aria-hidden />
            {t('pod.chat_timeline.download_markdown', { defaultValue: 'Download .md' })}
          </Button>
          {onSaveAsPage && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                onOpenChange(false)
                onSaveAsPage()
              }}>
              <RiSaveLine aria-hidden />
              {t('pod.content.save_as_page')}
            </Button>
          )}
          {result?.kind === 'ok' && (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  const url = URL.createObjectURL(result.blob)
                  const link = document.createElement('a')
                  link.href = url
                  link.download = `${filenameBase.replace(/[/\\:*?"<>|]/g, '_') || 'conversation-excerpt'}.png`
                  link.click()
                  setTimeout(() => URL.revokeObjectURL(url), 1000)
                }}>
                <RiDownloadLine aria-hidden />
                {t('pod.chat_timeline.download_png', { defaultValue: 'Download PNG' })}
              </Button>
              {typeof ClipboardItem !== 'undefined' && navigator.clipboard?.write && (
                <Button
                  variant="default"
                  size="sm"
                  onClick={async () => {
                    try {
                      const item = new ClipboardItem({ 'image/png': Promise.resolve(result.blob) })
                      await navigator.clipboard.write([item])
                      markCopied('image')
                      toast.success(t('pod.chat_timeline.copied'))
                    } catch {
                      toast.error(t('pod.chat.copy_failed'))
                    }
                  }}>
                  {copiedKind === 'image' ? <RiCheckLine aria-hidden /> : <RiImageLine aria-hidden />}
                  {t('pod.chat_timeline.copy_png', { defaultValue: 'Copy PNG' })}
                </Button>
              )}
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
