import { useSyncExternalStore } from 'react'

/** Where ui-sdk mounts a popup's DOM; `null` keeps the popup in place beside its trigger. */
type PopupContainer = Element | DocumentFragment | null | undefined

const subscribe = () => () => {}

/**
 * ui-sdk renders a popup in place by default, so the popup would take the text styles of the element around its
 * trigger and match that element's child selectors, such as a field's `*:w-full`. The kit mounts every popup in
 * `document.body` instead, where only the popup's own classes style it, and ui-sdk still keeps the popup's keyboard
 * order beside its trigger. A caller that needs another place passes `container`. The server snapshot leaves the
 * popup in place, so markup rendered on the server hydrates before the popup moves to the body.
 */
function usePopupContainer(container: PopupContainer) {
  const body = useSyncExternalStore(
    subscribe,
    () => document.body,
    () => undefined
  )
  return container === undefined ? body : container
}

export { usePopupContainer, type PopupContainer }
