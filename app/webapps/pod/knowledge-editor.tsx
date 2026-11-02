import { BlockEditor } from '@ankole/block-editor'
import { parseXml } from '@ankole/block-editor/document'
import { PageSession, type EditorHost, type EditorLabels } from '@ankole/block-editor/editor'
import { useRef } from 'react'

/** The edit session lives only while the author is editing this knowledge page. */
export default function KnowledgeEditor({
  xml,
  host,
  labels,
  disabled,
  onChange,
  onError
}: {
  xml: string
  host: EditorHost
  labels: Partial<EditorLabels>
  disabled: boolean
  onChange: (xml: string) => void
  onError: (error: unknown) => void
}) {
  const session = useRef<PageSession | null>(null)
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
        editor.focus()
        return () => {
          current.dispose()
          if (session.current === current) session.current = null
        }
      }}
      onChange={() => {
        if (session.current) onChange(session.current.readXml().xml)
      }}
    />
  )
}
