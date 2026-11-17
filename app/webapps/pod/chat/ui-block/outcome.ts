import type { UIBlockFailure } from './compile'

/** How Pod settled one `ui` block of an Agent reply: usable, or shown as code for the stated reason. */
export type UIBlockOutcome = {
  failure?: UIBlockFailure
  /** The Signal that the reply answers, which `conversation_messages.signal_id` records. */
  signalID: string
}

const MAX_REPORTED = 200
/** The blocks that the listeners heard most recently, by reply Signal and block source. */
const reported = new Set<string>()

/** Listeners for block outcomes. An edition adds one here to count how the blocks of Agent replies come out. */
export const uiBlockOutcomeListeners = new Set<(outcome: UIBlockOutcome) => void>()

/**
 * Records how one settled block came out. Pod writes the reason for an unusable block to the console, where an
 * operator can read it. The listeners hear the block when its reply carries a Signal, and they hear it once while
 * the block stays among the 200 that the page reported most recently, so a block that mounts again is not
 * counted again.
 */
export function recordUIBlockOutcome(code: string, failure: UIBlockFailure | undefined, signalID: string | undefined) {
  if (failure) console.warn('[Ankole] A ui block is shown as code', failure)
  if (!signalID || uiBlockOutcomeListeners.size === 0) return
  const key = `${signalID}\n${code}`
  if (reported.has(key)) return
  reported.add(key)
  if (reported.size > MAX_REPORTED) reported.delete(reported.values().next().value!)
  for (const listener of uiBlockOutcomeListeners) listener(failure ? { failure, signalID } : { signalID })
}
