import { Button, cn, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiTextWrap } from '@remixicon/react'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

export function CodeBlockView({ code, language }: { code: string; language?: string }) {
  const { t } = useTranslation()
  const [highlighted, setHighlighted] = useState<{ language?: string; html: string }>()
  const [wrap, setWrap] = useState(false)
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => {
    let current = true
    void import('shiki')
      .then(async shiki => {
        const lang = language && language in shiki.bundledLanguages ? language : 'text'
        const html = await shiki.codeToHtml(code, {
          lang,
          themes: { light: 'github-light', dark: 'github-dark' }
        })
        if (current) setHighlighted({ language, html })
      })
      .catch(() => {
        // Plain code stays available when a language or the highlighter cannot load.
      })
    return () => {
      current = false
    }
  }, [code, language])
  useEffect(() => () => clearTimeout(timer.current), [])
  const html = highlighted?.language === language ? highlighted?.html : undefined
  return (
    <div className={cn('pod-chat-code', wrap && 'pod-chat-code-wrap')}>
      <div className="pod-chat-code-header">
        <span>{language || t('pod.chat_timeline.plain_text')}</span>
        <div>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-pressed={wrap}
            title={t('pod.chat_timeline.wrap_code')}
            aria-label={t('pod.chat_timeline.wrap_code')}
            onClick={() => setWrap(!wrap)}>
            <RiTextWrap aria-hidden />
          </Button>
          <Button
            variant="ghost"
            size="xs"
            onClick={async () => {
              try {
                await navigator.clipboard.writeText(code)
                setCopied(true)
                clearTimeout(timer.current)
                timer.current = setTimeout(() => setCopied(false), 1500)
              } catch {
                toast.error(t('pod.chat.copy_failed'))
              }
            }}>
            {copied ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
            {t(copied ? 'pod.chat_timeline.copied' : 'pod.chat.copy_code')}
          </Button>
        </div>
      </div>
      {html ? (
        <div className="pod-chat-code-body" dangerouslySetInnerHTML={{ __html: html }} />
      ) : (
        <div className="pod-chat-code-body">
          <pre>
            <code>{code}</code>
          </pre>
        </div>
      )}
    </div>
  )
}
