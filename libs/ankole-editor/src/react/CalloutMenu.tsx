import { useRef } from 'react'
import { createPortal } from 'react-dom'
import { Button, Input } from '@ankole/uikit'
import { CalloutIcon, CalloutTone, calloutMenu, openCalloutMenu, tones } from '../blocks/callout'
import type { Mark } from '../core/doc'
import { dispatchStep } from '../editor/block-insert'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { useAnchoredOverlay } from './anchored-overlay'

export function CalloutMenu() {
  const editor = useEditor()
  const label = useEditorLabel()
  const pos = useEditorState(state => state.field(calloutMenu, false) ?? null)
  const panel = useRef<HTMLDivElement>(null)
  const close = () => editor.dispatch({ effects: openCalloutMenu.of(null) })
  const position = useAnchoredOverlay({
    open: pos !== null,
    panelRef: panel,
    anchor: () => (pos === null ? null : (editor.nodeDOM(pos)?.getBoundingClientRect() ?? null)),
    onClose: close,
    shouldIgnore: target => !!target.closest('.callout-icon'),
    dependencies: [pos]
  })
  if (pos === null) return null
  const node = editor.state.doc.nodeAt(pos)
  const set = (mark: Mark) => {
    if (editor.state.readOnly) return
    dispatchStep(editor, { changes: { from: pos, add: mark }, userEvent: 'callout.configure' })
  }
  return createPortal(
    <div
      ref={panel}
      className="ankole-editor-overlay callout-menu ceramic ceramic-primary"
      role="dialog"
      aria-label={label('callout_style')}
      style={position ?? { visibility: 'hidden' }}
      onKeyDown={event => {
        if (event.key === 'Escape') {
          close()
          editor.focus()
        }
      }}>
      <label>
        {label('callout_icon')}
        <Input
          aria-label={label('callout_icon')}
          value={node?.mark(CalloutIcon) ?? '💡'}
          onChange={event => set(CalloutIcon.of(event.target.value))}
        />
      </label>
      <div className="callout-icon-options">
        {['💡', '📌', 'ℹ️', '✅', '⚠️', '❗'].map(icon => (
          <Button key={icon} variant="ghost" size="icon-xs" onClick={() => set(CalloutIcon.of(icon))}>
            {icon}
          </Button>
        ))}
      </div>
      <div role="group" aria-label={label('callout_tone')} className="callout-tone-options">
        {tones.map(tone => (
          <Button
            key={tone}
            variant="ghost"
            size="xs"
            data-tone={tone}
            aria-pressed={(node?.mark(CalloutTone) ?? 'info') === tone}
            onClick={() => set(CalloutTone.of(tone))}>
            {label(`callout_${tone}`)}
          </Button>
        ))}
      </div>
    </div>,
    document.body
  )
}
