import type { Frame, Locator } from 'playwright-core'
import { BrowserDataError } from '../errors'

export async function selectByLabelOrValue(
  frame: Frame,
  locator: Locator,
  value: string,
  deadline: number
): Promise<void> {
  let comboboxOpened = false
  let comboboxTyped = false
  let openedFromClosed = false
  const preOpenListboxes = await frame.evaluateHandle(() => new Set<Element>())

  try {
    while (Date.now() < deadline) {
      const timeout = Math.max(1, deadline - Date.now())
      const match = await locator.evaluateHandle(
        (element, { targetValue }) => {
          const select = element instanceof HTMLSelectElement ? element : element.closest('label')?.control
          if (select instanceof HTMLSelectElement) {
            const options = Array.from(select.options)
            return (
              options.find(option => option.label === targetValue) ??
              options.find(option => option.value === targetValue) ??
              null
            )
          }

          const candidates: Element[] = [element]
          const labelFor = element.closest('label')?.htmlFor
          if (labelFor) {
            const byId = element.ownerDocument.getElementById(labelFor)
            if (byId) {
              candidates.push(byId)
              const byIdNested = byId.querySelector('[role="combobox"], [aria-haspopup="listbox"]')
              if (byIdNested) candidates.push(byIdNested)
            }
          }
          const nested = element.querySelector('[role="combobox"], [aria-haspopup="listbox"]')
          if (nested) candidates.push(nested)

          const combobox = candidates.find(candidate => {
            const role = candidate.getAttribute('role')
            const hasPopup = candidate.getAttribute('aria-haspopup')
            return role === 'combobox' || hasPopup === 'listbox'
          })
          if (!combobox) {
            throw new Error('Expected a select control or role="combobox"')
          }
          const expanded = combobox.getAttribute('aria-expanded') === 'true'
          return {
            kind: 'combobox' as const,
            expanded,
            isTextInput:
              (combobox instanceof HTMLInputElement &&
                !['button', 'checkbox', 'radio', 'submit', 'reset'].includes(combobox.type)) ||
              combobox.querySelector(
                'input:not([type="hidden"]):not([type="button"]):not([type="checkbox"]):not([type="radio"]):not([type="submit"]):not([type="reset"]):not([disabled])'
              ) !== null
          }
        },
        { targetValue: value },
        { timeout }
      )

      try {
        const optionElement = match.asElement()
        if (optionElement) {
          await locator.selectOption(optionElement, { timeout: Math.max(1, deadline - Date.now()) })
          return
        }
        const meta = (await match.jsonValue()) as null | {
          kind: 'combobox'
          expanded: boolean
          isTextInput: boolean
        }
        if (meta?.kind === 'combobox') {
          if (!meta.expanded && !comboboxOpened) {
            await snapshotVisibleListboxes(locator, preOpenListboxes, Math.max(1, deadline - Date.now()))
            await clickComboboxTrigger(locator, Math.max(1, deadline - Date.now()))
            comboboxOpened = true
            openedFromClosed = true
          }
          if (await clickMatchingAriaOption(locator, preOpenListboxes, openedFromClosed, value, deadline)) {
            return
          }
          if (meta.isTextInput && !comboboxTyped) {
            await fillComboboxInput(locator, value, Math.max(1, deadline - Date.now()))
            comboboxTyped = true
            if (await clickMatchingAriaOption(locator, preOpenListboxes, openedFromClosed, value, deadline)) {
              return
            }
          }
        }
      } finally {
        await match.dispose()
      }

      await Bun.sleep(Math.min(100, Math.max(0, deadline - Date.now())))
    }
  } finally {
    await preOpenListboxes.dispose().catch(() => undefined)
  }

  throw new BrowserDataError('timeout', 'select option was unavailable before the command deadline', {
    retryable: true
  })
}

async function snapshotVisibleListboxes(
  locator: Locator,
  preOpenListboxes: Awaited<ReturnType<Frame['evaluateHandle']>>,
  timeout: number
): Promise<void> {
  await locator.evaluate(
    (element, preOpen) => {
      for (const listbox of Array.from(element.ownerDocument.querySelectorAll('[role="listbox"]'))) {
        const htmlEl = listbox as HTMLElement
        if (htmlEl.hidden) continue
        const style = getComputedStyle(htmlEl)
        if (style.display === 'none' || style.visibility === 'hidden') continue
        const rect = htmlEl.getBoundingClientRect()
        if (rect.width > 0 && rect.height > 0) preOpen.add(listbox)
      }
    },
    preOpenListboxes,
    { timeout }
  )
}

async function clickComboboxTrigger(locator: Locator, timeout: number): Promise<void> {
  const handle = await locator.evaluateHandle(
    element => {
      if (element.getAttribute('role') === 'combobox' || element.getAttribute('aria-haspopup') === 'listbox') {
        return element
      }
      const nested = element.querySelector('[role="combobox"], [aria-haspopup="listbox"]')
      if (nested) return nested
      const labelFor = element.closest('label')?.htmlFor
      if (labelFor) {
        const associated = element.ownerDocument.getElementById(labelFor)
        if (associated) {
          if (
            associated.getAttribute('role') === 'combobox' ||
            associated.getAttribute('aria-haspopup') === 'listbox'
          ) {
            return associated
          }
          return associated.querySelector('[role="combobox"], [aria-haspopup="listbox"]') ?? associated
        }
      }
      return element
    },
    undefined,
    { timeout }
  )
  try {
    const target = handle.asElement()
    if (target) {
      await target.click({ timeout: Math.max(1, timeout) })
      return
    }
  } finally {
    await handle.dispose()
  }
  await locator.click({ timeout: Math.max(1, timeout) })
}

async function fillComboboxInput(locator: Locator, value: string, timeout: number): Promise<void> {
  const handle = await locator.evaluateHandle(
    element => {
      const selector =
        'input[role="combobox"]:not([disabled]), input:not([type="hidden"]):not([type="button"]):not([type="checkbox"]):not([type="radio"]):not([type="submit"]):not([type="reset"]):not([disabled])'
      const findInput = (root: Element): Element | null => {
        if (
          root instanceof HTMLInputElement &&
          !['hidden', 'button', 'checkbox', 'radio', 'submit', 'reset'].includes(root.type) &&
          !root.disabled
        ) {
          return root
        }
        return root.querySelector(selector)
      }
      const direct = findInput(element)
      if (direct) return direct
      const labelFor = element.closest('label')?.htmlFor
      if (labelFor) {
        const associated = element.ownerDocument.getElementById(labelFor)
        if (associated) {
          return findInput(associated) ?? associated
        }
      }
      return element
    },
    undefined,
    { timeout }
  )
  try {
    const target = handle.asElement()
    if (target) {
      await target.fill(value, { timeout: Math.max(1, timeout) })
      return
    }
  } finally {
    await handle.dispose()
  }
  await locator.fill(value, { timeout: Math.max(1, timeout) })
}

async function clickMatchingAriaOption(
  locator: Locator,
  preOpenListboxes: Awaited<ReturnType<Frame['evaluateHandle']>>,
  openedFromClosed: boolean,
  value: string,
  deadline: number
): Promise<boolean> {
  if (Date.now() >= deadline) return false
  const handle = await locator.evaluateHandle(
    (element, { target, preOpen, excludePreOpen }) => {
      const doc = element.ownerDocument
      const isVisible = (el: Element): boolean => {
        const htmlEl = el as HTMLElement
        if (htmlEl.hidden) return false
        const style = getComputedStyle(htmlEl)
        if (style.display === 'none' || style.visibility === 'hidden') return false
        const rect = htmlEl.getBoundingClientRect()
        return rect.width > 0 && rect.height > 0
      }

      const isSelectable = (el: Element): boolean => {
        if (el.getAttribute('aria-disabled') === 'true') return false
        if ((el as HTMLButtonElement).disabled === true) return false
        return isVisible(el)
      }

      const comboboxCandidates: Element[] = [element]
      const labelFor = element.closest('label')?.htmlFor
      if (labelFor) {
        const byId = doc.getElementById(labelFor)
        if (byId) {
          comboboxCandidates.push(byId)
          const byIdNested = byId.querySelector('[role="combobox"], [aria-haspopup="listbox"]')
          if (byIdNested) comboboxCandidates.push(byIdNested)
        }
      }
      const nested = element.querySelector('[role="combobox"], [aria-haspopup="listbox"]')
      if (nested) comboboxCandidates.push(nested)
      const combobox =
        comboboxCandidates.find(
          candidate =>
            candidate.getAttribute('role') === 'combobox' || candidate.getAttribute('aria-haspopup') === 'listbox'
        ) ?? element

      // Re-read aria-controls / aria-owns live after opening or typing into the combobox.
      const listboxIds = [combobox.getAttribute('aria-controls'), combobox.getAttribute('aria-owns')]
        .filter((id): id is string => Boolean(id))
        .flatMap(raw => raw.split(/\s+/))
        .filter(Boolean)

      let candidates: Element[] = []
      if (listboxIds.length > 0) {
        // Explicit ownership: never fall back to options belonging to other controls on the page.
        candidates = listboxIds
          .map(id => doc.getElementById(id))
          .filter((container): container is HTMLElement => container !== null)
          .flatMap(container => Array.from(container.querySelectorAll('[role="option"]')))
          .filter(isSelectable)
      } else {
        // Implicit ownership: check options nested inside the combobox wrapper first, then at most one
        // newly-opened / unowned visible listbox in the same document.
        const inlineOptions = Array.from(
          new Set([
            ...Array.from(combobox.querySelectorAll('[role="option"]')),
            ...Array.from(element.querySelectorAll('[role="option"]'))
          ])
        ).filter(isSelectable)
        if (inlineOptions.length > 0) {
          candidates = inlineOptions
        } else if (combobox.getAttribute('aria-expanded') === 'true' || excludePreOpen) {
          const ownedByOthers = new Set<string>()
          for (const owner of Array.from(doc.querySelectorAll('[aria-controls], [aria-owns]'))) {
            if (owner === combobox || element.contains(owner) || combobox.contains(owner) || owner.contains(combobox)) {
              continue
            }
            for (const attr of [owner.getAttribute('aria-controls'), owner.getAttribute('aria-owns')]) {
              if (!attr) continue
              for (const id of attr.split(/\s+/)) {
                if (id) ownedByOthers.add(id)
              }
            }
          }

          const unownedPopups = Array.from(doc.querySelectorAll('[role="listbox"]')).filter(listbox => {
            if (!isVisible(listbox)) return false
            if (excludePreOpen && (preOpen as Set<Element>).has(listbox)) return false
            if (listbox.id && ownedByOthers.has(listbox.id)) return false
            const enclosingCombo = listbox.closest('[role="combobox"]')
            if (
              enclosingCombo &&
              enclosingCombo !== combobox &&
              !element.contains(enclosingCombo) &&
              !combobox.contains(enclosingCombo)
            ) {
              return false
            }
            return true
          })

          if (unownedPopups.length === 1) {
            candidates = Array.from(unownedPopups[0]!.querySelectorAll('[role="option"]')).filter(isSelectable)
          }
        }
      }

      if (candidates.length === 0) return null

      const textOf = (el: Element): string =>
        (el.getAttribute('aria-label') || (el as HTMLElement).innerText || el.textContent || '').trim()

      const lowered = target.toLowerCase()
      return (
        candidates.find(el => textOf(el) === target) ??
        candidates.find(el => el.getAttribute('data-value') === target || el.getAttribute('value') === target) ??
        candidates.find(el => textOf(el).toLowerCase() === lowered) ??
        null
      )
    },
    { target: value, preOpen: preOpenListboxes, excludePreOpen: openedFromClosed },
    { timeout: Math.max(1, deadline - Date.now()) }
  )
  try {
    const element = handle.asElement()
    if (element) {
      await element.click({ timeout: Math.max(1, deadline - Date.now()) })
      return true
    }
  } finally {
    await handle.dispose()
  }
  return false
}
