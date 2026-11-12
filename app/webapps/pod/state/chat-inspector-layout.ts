import { createModel } from '@preact/signals-react'
import { browserStorage, panelWidth, type PanelWidthStorage } from './panel-width'

/**
 * A room's background-work panel opens as a 440px column beside the chat, the width that a narrow room's overlay
 * also takes. A resize keeps it at least 320px wide and leaves the chat column at least 300px, so the room's width
 * sets how wide the panel can grow; the saved width only has to stay below any real screen.
 */
export const CHAT_INSPECTOR_DEFAULT_WIDTH = 440
export const CHAT_INSPECTOR_MIN_WIDTH = 320
const CHAT_INSPECTOR_SAVED_MAX_WIDTH = 4096
/** The chat column beside the panel never narrows past this width. */
export const CHAT_COLUMN_MIN_WIDTH = 300

export const ChatInspectorLayoutModel = createModel((storage: PanelWidthStorage | undefined = browserStorage()) =>
  panelWidth(
    {
      storageKey: 'ankole.pod.chat-inspector-width',
      min: CHAT_INSPECTOR_MIN_WIDTH,
      max: CHAT_INSPECTOR_SAVED_MAX_WIDTH,
      initial: CHAT_INSPECTOR_DEFAULT_WIDTH
    },
    storage
  )
)
