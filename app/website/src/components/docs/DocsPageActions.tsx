import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@ankole/uikit/components/dropdown-menu'
import {
  RiArrowDownSLine,
  RiCheckLine,
  RiClaudeLine,
  RiCodeSSlashLine,
  RiErrorWarningLine,
  RiFileCopyLine,
  RiMarkdownLine,
  RiOpenaiLine
} from '@remixicon/react'
import { useEffect, useRef, useState } from 'react'

export interface DocsPageActionsLabels {
  copied: string
  copy: string
  copyFailed: string
  menu: string
  openChatgpt: string
  openClaude: string
  openCursor: string
  viewMarkdown: string
}

interface DocsPageActionsProps {
  labels: DocsPageActionsLabels
  /** Same-origin path of the page's Markdown version. */
  markdownPath: string
  /** Prompt that asks an assistant to read the page's public Markdown URL. */
  prompt: string
}

type CopyState = 'idle' | 'copied' | 'failed'

export default function DocsPageActions({ labels, markdownPath, prompt }: DocsPageActionsProps) {
  const [copyState, setCopyState] = useState<CopyState>('idle')
  const resetTimer = useRef<number | undefined>(undefined)

  useEffect(() => () => window.clearTimeout(resetTimer.current), [])

  const copyPage = async () => {
    try {
      await copyText(fetchText(markdownPath))
      setCopyState('copied')
    } catch {
      setCopyState('failed')
    }
    window.clearTimeout(resetTimer.current)
    resetTimer.current = window.setTimeout(() => setCopyState('idle'), 2000)
  }

  const openItems = [
    { icon: RiMarkdownLine, label: labels.viewMarkdown, href: markdownPath },
    {
      icon: RiOpenaiLine,
      label: labels.openChatgpt,
      href: `https://chatgpt.com/?${new URLSearchParams({ hints: 'search', prompt })}`
    },
    {
      icon: RiClaudeLine,
      label: labels.openClaude,
      href: `https://claude.ai/new?${new URLSearchParams({ q: prompt })}`
    },
    {
      icon: RiCodeSSlashLine,
      label: labels.openCursor,
      href: `https://cursor.com/link/prompt?${new URLSearchParams({ text: prompt })}`
    }
  ]

  const CopyIcon = copyState === 'copied' ? RiCheckLine : copyState === 'failed' ? RiErrorWarningLine : RiFileCopyLine
  const copyLabel = copyState === 'copied' ? labels.copied : copyState === 'failed' ? labels.copyFailed : labels.copy

  return (
    <div className="not-prose -mt-3 mb-2 inline-flex items-stretch border border-border">
      <button
        type="button"
        onClick={copyPage}
        className="inline-flex h-8 cursor-pointer items-center gap-1.5 px-3 font-mono text-[11px] text-muted-foreground transition-colors hover:bg-background-secondary hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none">
        <CopyIcon aria-hidden="true" className="size-3.5" />
        <span aria-live="polite">{copyLabel}</span>
      </button>
      <DropdownMenu>
        <DropdownMenuTrigger
          aria-label={labels.menu}
          title={labels.menu}
          className="inline-flex h-8 items-center border-l border-border px-2 text-muted-foreground transition-colors hover:bg-background-secondary hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none">
          <RiArrowDownSLine aria-hidden="true" className="size-4" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-auto min-w-52">
          {openItems.map(item => (
            <DropdownMenuItem
              key={item.label}
              onClick={() => window.open(item.href, '_blank', 'noopener,noreferrer')}
              className="flex cursor-pointer items-center gap-2.5 px-4 py-2">
              <item.icon aria-hidden="true" className="size-4" />
              <span>{item.label}</span>
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  )
}

async function fetchText(path: string): Promise<string> {
  const response = await fetch(path)
  if (!response.ok) throw new Error(`GET ${path} returned ${response.status}`)
  return response.text()
}

async function copyText(text: Promise<string>) {
  // Safari permits a clipboard write only while the click is being handled. A ClipboardItem
  // accepts the pending download, so the write starts before the fetch completes.
  if (typeof ClipboardItem !== 'undefined' && navigator.clipboard?.write) {
    const blob = text.then(value => new Blob([value], { type: 'text/plain' }))
    await navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })])
    return
  }
  await navigator.clipboard.writeText(await text)
}
