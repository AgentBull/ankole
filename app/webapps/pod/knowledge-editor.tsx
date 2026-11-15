import { BlockEditor } from '@ankole/block-editor'
import { parseXml } from '@ankole/block-editor/document'
import { PageSession, type EditorHost, type EditorLabels } from '@ankole/block-editor/editor'
import { useRef, type RefObject } from 'react'

/** The edit session lives only while the author is editing this knowledge page. */
export default function KnowledgeEditor({
  xml,
  host,
  labels,
  disabled,
  flushRef,
  onChange,
  onError
}: {
  xml: string
  host: EditorHost
  labels: Partial<EditorLabels>
  disabled: boolean
  flushRef?: RefObject<(() => void) | null>
  onChange: (xml: string) => void
  onError: (error: unknown) => void
}) {
  const session = useRef<PageSession | null>(null)
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange
  return (
    <BlockEditor
      kind="knowledge"
      initial={parseXml(xml)}
      readOnly={disabled}
      host={host}
      labels={labels}
      onError={onError}
      onReady={editor => {
        const current = new PageSession(editor)
        session.current = current
        if (flushRef) {
          flushRef.current = () => {
            editor.flush()
            if (session.current && session.current.revision > 0) {
              onChangeRef.current(session.current.readXml().xml)
            }
          }
        }
        editor.focus()
        return () => {
          if (flushRef) flushRef.current = null
          current.dispose()
          if (session.current === current) session.current = null
        }
      }}
      onChange={() => {
        if (session.current) onChangeRef.current(session.current.readXml().xml)
      }}
    />
  )
}
