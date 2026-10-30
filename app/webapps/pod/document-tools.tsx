import {
  DropdownMenuCheckboxItem,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  toast
} from '@ankole/uikit'
import {
  RiBarChartBoxLine,
  RiChatQuoteLine,
  RiHistoryLine,
  RiDownloadLine,
  RiFileCopyLine,
  RiHashtag,
  RiMarkdownLine,
  RiText
} from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQueryClient } from '@tanstack/react-query'
import { useEffect, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import { requestErrorMessage } from '../common/request-errors'
import { type PageDetail } from './content-api'
import { contentError } from './content-errors'
import { documentPlainText } from './state/document-tools'
import {
  documentMarkdownForExport,
  downloadDocument,
  loadDocumentPrincipals,
  loadDocumentReferences
} from './state/document-export'
import type { DocumentToolsModel } from './state/document-tools-model'
import type { PageDraftModel } from './state/page-draft'

type Tools = InstanceType<typeof DocumentToolsModel>

export function DocumentMenuItems({
  detail,
  draft,
  model,
  openInsights,
  openComments,
  openHistory,
  mobile
}: {
  detail: PageDetail
  draft: InstanceType<typeof PageDraftModel>
  model: Tools
  openInsights(): void
  openComments(): void
  openHistory?: () => void
  mobile: boolean
}) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const shortcut = typeof navigator !== 'undefined' && navigator.platform.includes('Mac') ? '⌘⇧' : 'Ctrl+Shift+'
  const copy = async (format: 'markdown' | 'text') => {
    try {
      const xml = draft.xml.value
      const title = draft.title.value
      const content = Promise.all([
        loadDocumentReferences(client, [xml]),
        loadDocumentPrincipals([xml], detail.page.id)
      ]).then(([references, principals]) =>
        format === 'markdown'
          ? documentMarkdownForExport(detail.page.id, xml, title, detail.page.icon, references, principals)
          : documentPlainText(xml, {
              resolveReference: ref => references.get(ref),
              resolvePrincipal: uid => principals.get(uid)
            })
      )
      // Start the clipboard write in the click gesture, including while reference titles are loading.
      if (typeof ClipboardItem !== 'undefined' && navigator.clipboard.write) {
        await navigator.clipboard.write([
          new ClipboardItem({
            'text/plain': content.then(text => new Blob([text], { type: 'text/plain' }))
          })
        ])
      } else {
        await navigator.clipboard.writeText(await content)
      }
      toast.success(t(format === 'markdown' ? 'pod.document.copied_markdown' : 'pod.document.copied_text'))
    } catch (error) {
      toast.error(requestErrorMessage(contentError(error)))
    }
  }
  const download = async () => {
    const pending = toast.loading(t('pod.document.preparing_export'))
    try {
      await downloadDocument(client, {
        pageID: detail.page.id,
        xml: draft.xml.value,
        title: draft.title.value,
        icon: detail.page.icon
      })
    } catch (error) {
      toast.error(requestErrorMessage(contentError(error)))
    } finally {
      toast.dismiss(pending)
    }
  }
  return (
    <>
      <DropdownMenuSeparator />
      <DropdownMenuItem onClick={openComments}>
        <RiChatQuoteLine aria-hidden />
        {t('pod.document.comments')}
      </DropdownMenuItem>
      {openHistory && (
        <DropdownMenuItem onClick={openHistory}>
          <RiHistoryLine aria-hidden />
          {t('pod.document.history')}
        </DropdownMenuItem>
      )}
      <DropdownMenuItem onClick={openInsights} aria-keyshortcuts="Meta+Shift+I Control+Shift+I">
        <RiBarChartBoxLine aria-hidden />
        {t('pod.document.insights')}
        <DropdownMenuShortcut>{shortcut}I</DropdownMenuShortcut>
      </DropdownMenuItem>
      {!mobile && (
        <DropdownMenuCheckboxItem
          checked={model.showStats.value}
          onCheckedChange={model.setShowStats}
          aria-keyshortcuts="Meta+Shift+G Control+Shift+G">
          <RiHashtag aria-hidden />
          {t('pod.document.show_editing_stats')}
          <DropdownMenuShortcut>{shortcut}G</DropdownMenuShortcut>
        </DropdownMenuCheckboxItem>
      )}
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>
          <RiDownloadLine aria-hidden />
          {t('pod.document.export')}
        </DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={download}>
            <RiMarkdownLine aria-hidden />
            Markdown
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
      <DropdownMenuSub>
        <DropdownMenuSubTrigger>
          <RiFileCopyLine aria-hidden />
          {t('pod.document.copy')}
        </DropdownMenuSubTrigger>
        <DropdownMenuSubContent>
          <DropdownMenuItem onClick={() => void copy('markdown')}>
            <RiMarkdownLine aria-hidden />
            {t('pod.document.copy_markdown')}
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => void copy('text')}>
            <RiText aria-hidden />
            {t('pod.document.copy_text')}
          </DropdownMenuItem>
        </DropdownMenuSubContent>
      </DropdownMenuSub>
    </>
  )
}

export function DocumentStats({ model, content }: { model: Tools; content: RefObject<HTMLDivElement | null> }) {
  useSignals()
  const { t, i18n } = useTranslation()
  useEffect(() => {
    const update = () => {
      const selection = document.getSelection()
      model.selectedText.value =
        selection && content.current?.contains(selection.anchorNode) && content.current.contains(selection.focusNode)
          ? selection.toString()
          : ''
    }
    document.addEventListener('selectionchange', update)
    return () => document.removeEventListener('selectionchange', update)
  }, [model, content])
  if (!model.showStats.value) return null
  const stats = model.stats.value
  const selected = !!model.selectedText.value
  const number = (value: number) => new Intl.NumberFormat(i18n.language).format(value)
  return (
    <footer
      className="pod-document-stats sticky bottom-0 flex shrink-0 flex-wrap justify-end gap-x-4 gap-y-1.5 bg-background px-4 py-2 text-xs text-fg-tertiary select-none pointer-events-none print:hidden"
      aria-label={t('pod.document.editing_stats')}>
      <span>{t(selected ? 'pod.document.words_selected' : 'pod.document.words', { count: number(stats.words) })}</span>
      <span>
        {t(selected ? 'pod.document.characters_selected' : 'pod.document.characters', {
          count: number(stats.characters)
        })}
      </span>
      {!selected && (
        <>
          <span>{t('pod.document.paragraphs', { count: number(stats.paragraphs) })}</span>
          {stats.readingTime > 0 && <span>{t('pod.document.reading_time', { count: number(stats.readingTime) })}</span>}
        </>
      )}
    </footer>
  )
}
