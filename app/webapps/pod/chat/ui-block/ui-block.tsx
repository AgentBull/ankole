import { JSONUIProvider, Renderer } from '@json-render/react'
import { useEffect, useMemo } from 'react'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../../common/external-translation-guard'
import { CodeBlockView } from '../code-block-view'
import { compileUIBlock, explainUIBlockFailure, validateUIBlockState } from './compile'
import { recordUIBlockOutcome } from './outcome'
import { uiBlockRegistry } from './registry'
import { useLatestHandlers } from './use-latest-handlers'
import { useViewState } from './view-state'

/** Renders a fenced `ui` block of a chat message. A settled block without a usable spec shows its source. */
export default function UIBlock({
  code,
  streaming,
  signalID,
  onReply
}: {
  code: string
  streaming: boolean
  /** The Signal that the reply answers. Pod reports the outcome of a block only when its reply carries one. */
  signalID?: string
  /** Receives the text of a reply button. A surface without a composer leaves it out, and the button does nothing. */
  onReply?: (text: string) => void
}) {
  const spec = useMemo(() => compileUIBlock(code, streaming), [code, streaming])
  const store = useViewState(
    code,
    streaming,
    spec?.state,
    spec ? candidate => validateUIBlockState(spec, candidate) : undefined
  )
  const handlers = useLatestHandlers({
    reply: params => {
      if (typeof params.text === 'string' && params.text.trim()) onReply?.(params.text)
    }
  })
  const usable = Boolean(spec)
  useEffect(() => {
    if (!streaming) recordUIBlockOutcome(code, usable ? undefined : explainUIBlockFailure(code), signalID)
  }, [streaming, usable, code, signalID])
  if (!spec) return streaming ? null : <CodeBlockView code={code} language="ui" />
  return (
    <div
      {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
      data-testid="chat-ui-block"
      className={withExternalTranslationGuardClass('pod-chat-ui-block')}>
      <JSONUIProvider registry={uiBlockRegistry} store={store} handlers={handlers}>
        <Renderer spec={spec} registry={uiBlockRegistry} loading={streaming} />
      </JSONUIProvider>
    </div>
  )
}
