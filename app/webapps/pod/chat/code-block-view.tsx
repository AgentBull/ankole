import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, cn, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiTextWrap } from '@remixicon/react'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../common/external-translation-guard'
import { useDebouncedValue } from '../../common/use-debounced-value'

export function CodeBlockView({ code, language }: { code: string; language?: string }) {
  const { t } = useTranslation()
  const [highlighted, setHighlighted] = useState<{ code: string; language: string; html: string }>()
  const settledCode = useDebouncedValue(code, 150)
  const [wrap, setWrap] = useState(false)
  const [copied, markCopied] = useCopyFeedback(false)
  useEffect(() => {
    if (!language || ['text', 'txt', 'plaintext'].includes(language)) return
    let current = true
    void import('shiki')
      .then(async shiki => {
        const lang = language && language in shiki.bundledLanguages ? language : 'text'
        if (!current) return
        const html = await shiki.codeToHtml(settledCode, {
          lang,
          themes: { light: 'github-light', dark: 'github-dark' }
        })
        if (current) setHighlighted({ code: settledCode, language, html })
      })
      .catch(() => {
        // Plain code stays available when a language or the highlighter cannot load.
      })
    return () => {
      current = false
    }
  }, [settledCode, language])
  const html = highlighted?.code === code && highlighted.language === language ? highlighted.html : undefined
  return (
    <div
      {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
      className={withExternalTranslationGuardClass(
        cn('pod-chat-code code-surface my-3 max-w-full', wrap && 'pod-chat-code-wrap')
      )}>
      <div className="code-toolbar">
        <span className="mr-auto">{language || t('pod.chat_timeline.plain_text')}</span>
        <div className="flex items-center gap-0.5">
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
                markCopied(true)
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
