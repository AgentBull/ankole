import { AnimatePresence, motion, useReducedMotion } from 'motion/react'
import { useEffect, useState, type ReactNode } from 'react'

const EXPRESSIVE = [0.4, 0.14, 0.3, 1] as const

/** One pass of the runtime loop: a signal arrives, an actor runs, the ledger commits. */
interface Flow {
  source: string
  detail: string
  cell: number
  event: string
}

const FLOWS: Flow[] = [
  { source: 'lark.thread', detail: '#product-launch', cell: 8, event: 'turn.commit' },
  { source: 'github.issue', detail: 'ankole#412', cell: 3, event: 'outbox.send' },
  { source: 'schedule.cron', detail: '09:00 · daily', cell: 14, event: 'reminder.ack' },
  { source: 'webhook.alert', detail: 'pager · p1', cell: 11, event: 'decision.log' }
]

/** Milliseconds for each phase: arrive, dispatch, run, commit. */
const PHASE_MS = [820, 520, 1600, 980]

const ACTOR_TAGS = [
  'cs',
  'dev',
  'qa',
  'ops',
  'res',
  'cs',
  'dev',
  'ops',
  'cs',
  'res',
  'qa',
  'dev',
  'ops',
  'cs',
  'sre',
  'res',
  'dev',
  'qa'
]

/** Cells that already hold a hibernating session, so the grid is never empty. */
const OCCUPIED = new Set([1, 3, 6, 8, 11, 14, 16])

/** Deterministic clock, so the server output and the first client render agree. */
function stamp(tick: number): string {
  const seconds = 14 * 3600 + 32 * 60 + 7 + tick * 7
  const parts = [Math.floor(seconds / 3600) % 24, Math.floor(seconds / 60) % 60, seconds % 60]
  return parts.map(value => String(value).padStart(2, '0')).join(':')
}

interface LedgerRow {
  tick: number
  event: string
}

const SEED_LEDGER: LedgerRow[] = [
  { tick: -2, event: 'session.resume' },
  { tick: -1, event: 'memory.write' }
]

interface BandProps {
  label: string
  active: boolean
  children: ReactNode
}

/** A panel band. Its left keyline draws downward while that stage holds the flow. */
function Band({ label, active, children }: BandProps) {
  return (
    <section className="relative border-b border-border pl-4 last:border-b-0">
      <span className="absolute inset-y-0 left-0 w-0.5 bg-border" aria-hidden="true" />
      <motion.span
        className="absolute inset-y-0 left-0 w-0.5 origin-top bg-brand-60 dark:bg-brand-40"
        aria-hidden="true"
        initial={false}
        animate={{ scaleY: active ? 1 : 0 }}
        transition={{ duration: 0.42, ease: EXPRESSIVE }}
      />
      <h3 className="px-4 pt-3 pb-2 font-mono text-[10px] tracking-[0.14em] text-fg-quaternary uppercase">{label}</h3>
      {children}
    </section>
  )
}

export interface HeroRuntimeLabels {
  live: string
  signals: string
  actors: string
  ledger: string
}

export default function HeroRuntime({ labels }: { labels: HeroRuntimeLabels }) {
  const reduced = useReducedMotion()
  const [step, setStep] = useState(0)
  const [ledger, setLedger] = useState<LedgerRow[]>(SEED_LEDGER)

  const flowIndex = Math.floor(step / PHASE_MS.length) % FLOWS.length
  const phase = step % PHASE_MS.length
  const flow = FLOWS[flowIndex]

  /*
   * A hidden tab keeps timers running but stops the animation frames, so the loop
   * would advance without drawing and then catch up all at once. Hold it instead.
   */
  useEffect(() => {
    if (reduced) return

    let timer = 0
    const advance = () => {
      timer = window.setTimeout(() => setStep(current => current + 1), PHASE_MS[phase])
    }
    const sync = () => {
      window.clearTimeout(timer)
      if (!document.hidden) advance()
    }

    sync()
    document.addEventListener('visibilitychange', sync)
    return () => {
      window.clearTimeout(timer)
      document.removeEventListener('visibilitychange', sync)
    }
  }, [step, phase, reduced])

  useEffect(() => {
    if (reduced || phase !== 3) return
    setLedger(current =>
      current.at(-1)?.tick === step ? current : [...current, { tick: step, event: flow.event }].slice(-3)
    )
  }, [step, phase, flow.event, reduced])

  const running = reduced || phase >= 2

  return (
    <motion.div
      className="relative border border-border bg-background"
      data-reveal
      initial={reduced ? false : { opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.56, ease: [0, 0, 0.3, 1], delay: 0.24 }}>
      <header className="flex items-center justify-between border-b border-border px-4 py-2.5">
        <span className="font-mono text-[11px] text-muted-foreground">ankole · runtime</span>
        <span className="inline-flex items-center gap-2 font-mono text-[11px] text-brand-60 dark:text-brand-40">
          <span className="relative flex size-1.5">
            <span
              className="absolute inset-0 bg-current motion-safe:animate-[signal-ping_2.4s_var(--ease-expressive)_infinite]"
              aria-hidden="true"
            />
            <span className="size-1.5 bg-current" aria-hidden="true" />
          </span>
          {labels.live}
        </span>
      </header>

      <Band label={labels.signals} active={reduced || phase === 0}>
        <ul className="list-none p-0 pb-3">
          {FLOWS.map((item, index) => {
            const selected = index === flowIndex
            return (
              <li
                key={item.source}
                className="flex items-center gap-3 px-4 py-1.5 font-mono text-[11px] transition-colors duration-200 ease-[var(--ease-productive)]">
                <span
                  className={`size-1.5 shrink-0 transition-colors duration-200 ${
                    selected ? 'bg-brand-60 dark:bg-brand-40' : 'bg-gray-30 dark:bg-gray-70'
                  }`}
                  aria-hidden="true"
                />
                <span className={selected ? 'text-foreground' : 'text-fg-quaternary'}>{item.source}</span>
                <span className="ml-auto truncate text-fg-quaternary">{item.detail}</span>
              </li>
            )
          })}
        </ul>
      </Band>

      <Band label={labels.actors} active={reduced || phase === 1 || phase === 2}>
        <div className="grid grid-cols-6 gap-px bg-border px-0 mx-4 mb-4 border border-border">
          {ACTOR_TAGS.map((tag, index) => {
            const isActive = running && index === flow.cell
            const isOccupied = OCCUPIED.has(index)
            return (
              <div
                key={`${tag}-${index}`}
                className={`relative flex h-9 items-center justify-center overflow-hidden font-mono text-[9px] transition-colors duration-200 ease-[var(--ease-productive)] ${
                  isActive
                    ? 'bg-brand-60 text-white dark:bg-brand-50'
                    : isOccupied
                      ? 'bg-background-secondary text-fg-tertiary'
                      : 'bg-background text-fg-quaternary/70'
                }`}>
                {tag}
                {isActive && !reduced && (
                  <motion.span
                    key={`run-${flowIndex}`}
                    className="absolute inset-x-0 bottom-0 h-0.5 origin-left bg-white/80"
                    aria-hidden="true"
                    initial={{ scaleX: 0 }}
                    animate={{ scaleX: 1 }}
                    transition={{ duration: PHASE_MS[2] / 1000, ease: 'linear' }}
                  />
                )}
              </div>
            )
          })}
        </div>
      </Band>

      <Band label={labels.ledger} active={reduced || phase === 3}>
        <ul className="list-none p-0 pb-3">
          <AnimatePresence initial={false}>
            {ledger.map(row => (
              <motion.li
                key={`${row.tick}-${row.event}`}
                className="flex items-center gap-3 overflow-hidden px-4 font-mono text-[11px]"
                initial={reduced ? false : { height: 0, opacity: 0 }}
                animate={{ height: '1.75rem', opacity: 1 }}
                exit={{ height: 0, opacity: 0 }}
                transition={{ duration: 0.36, ease: EXPRESSIVE }}>
                <span className="text-fg-quaternary">{stamp(row.tick)}</span>
                <span className="text-foreground">{row.event}</span>
                <span className="ml-auto text-brand-60 dark:text-brand-40">committed</span>
              </motion.li>
            ))}
          </AnimatePresence>
        </ul>
      </Band>
    </motion.div>
  )
}
