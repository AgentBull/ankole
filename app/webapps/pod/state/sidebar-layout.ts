import { createModel } from '@preact/signals-react'
import { browserStorage, panelWidth, type PanelWidthStorage } from './panel-width'

/** The sidebar opens at the design's 258px column, the narrowest width that a resize keeps. */
export const POD_SIDEBAR_MIN_WIDTH = 258
export const POD_SIDEBAR_MAX_WIDTH = 480

export const SidebarLayoutModel = createModel((storage: PanelWidthStorage | undefined = browserStorage()) =>
  panelWidth(
    {
      storageKey: 'ankole.pod.sidebar-width',
      min: POD_SIDEBAR_MIN_WIDTH,
      max: POD_SIDEBAR_MAX_WIDTH,
      initial: POD_SIDEBAR_MIN_WIDTH
    },
    storage
  )
)
