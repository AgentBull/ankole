import { createContext } from 'react'

/**
 * Brings an element inside a message to the middle of the view. Inside the timeline this goes through
 * the timeline's reading position, which otherwise keeps the view where the reader left it; elsewhere,
 * such as in a standalone dialog, the element scrolls itself into view.
 */
export const RevealInTimeline = createContext<(element: Element) => void>(element =>
  element.scrollIntoView({ block: 'center' })
)
