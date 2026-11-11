import { JSONUIProvider, Renderer } from '@json-render/react'
import { useMemo } from 'react'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../../common/external-translation-guard'
import { CodeBlockView } from '../code-block-view'
import { compileUIBlock } from './compile'
import { uiBlockRegistry } from './registry'
import { useLatestHandlers } from './use-latest-handlers'

/** Renders a fenced `ui` block of a chat message. A settled block without a usable spec shows its source. */
export default function UIBlock({
  code,
  streaming,
  onReply
}: {
  code: string
  streaming: boolean
  /** Receives the text of a reply button. A surface without a composer leaves it out, and the button does nothing. */
  onReply?: (text: string) => void
}) {
  const spec = useMemo(() => compileUIBlock(code, streaming), [code, streaming])
  const handlers = useLatestHandlers({
    reply: params => {
      if (typeof params.text === 'string' && params.text.trim()) onReply?.(params.text)
    }
  })
  if (!spec) return streaming ? null : <CodeBlockView code={code} language="ui" />
  return (
    <div
      {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
      data-testid="chat-ui-block"
      className={withExternalTranslationGuardClass('pod-chat-ui-block my-3')}>
      <JSONUIProvider registry={uiBlockRegistry} initialState={spec.state} handlers={handlers}>
        <Renderer spec={spec} registry={uiBlockRegistry} loading={streaming} />
      </JSONUIProvider>
    </div>
  )
}
