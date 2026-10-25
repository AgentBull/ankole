import { useEffect, useRef, useState, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'

type Turn = { id: string; text: string; preview?: string }

export function TurnRail({
  turns,
  scrollRef,
  onJump
}: {
  turns: Turn[]
  scrollRef: RefObject<HTMLElement | null>
  onJump(id: string): void
}) {
  const { t } = useTranslation()
  const [hover, setHover] = useState<{ index: number; top: number }>()
  const [visible, setVisible] = useState(new Set<string>())
  const nav = useRef<HTMLElement>(null)
  const ticks = useRef<HTMLDivElement>(null)
  const turnIDs = turns.map(turn => turn.id).join('|')
  useEffect(() => {
    const scroll = scrollRef.current
    if (!scroll) return
    const observer = new IntersectionObserver(
      entries =>
        setVisible(current => {
          const next = new Set(current)
          entries.forEach(entry => {
            const id = (entry.target as HTMLElement).dataset.chatMessageId!
            if (entry.isIntersecting) next.add(id)
            else next.delete(id)
          })
          return next
        }),
      { root: scroll, threshold: 0.2 }
    )
    for (const id of turnIDs.split('|')) {
      const element = scroll.querySelector(`[data-chat-message-id="${CSS.escape(id)}"]`)
      if (element) observer.observe(element)
    }
    return () => observer.disconnect()
  }, [turnIDs, scrollRef])
  const firstVisibleID = turns.find(turn => visible.has(turn.id))?.id
  useEffect(() => {
    const list = ticks.current
    const tick = firstVisibleID && list?.querySelector<HTMLElement>(`[data-turn-id="${CSS.escape(firstVisibleID)}"]`)
    if (!list || !tick) return
    if (tick.offsetTop < list.scrollTop) list.scrollTop = tick.offsetTop
    else if (tick.offsetTop + tick.offsetHeight > list.scrollTop + list.clientHeight) {
      list.scrollTop = tick.offsetTop + tick.offsetHeight - list.clientHeight
    }
  }, [firstVisibleID])
  if (turns.length <= 3) return null
  const point = (index: number, button: HTMLElement) => {
    const rect = button.getBoundingClientRect()
    setHover({ index, top: rect.top - nav.current!.getBoundingClientRect().top + rect.height / 2 })
  }
  const jump = (id: string) => {
    setHover(undefined)
    onJump(id)
  }
  const tabStop =
    hover?.index ??
    Math.max(
      0,
      turns.findIndex(turn => visible.has(turn.id))
    )
  return (
    <nav
      ref={nav}
      className="pod-chat-turn-rail"
      aria-label={t('pod.chat_timeline.turns')}
      onPointerLeave={() => setHover(undefined)}
      onBlur={event => {
        if (!event.currentTarget.contains(event.relatedTarget)) setHover(undefined)
      }}
      onKeyDown={event => {
        const buttons = Array.from(ticks.current?.querySelectorAll('button') ?? [])
        const index = buttons.indexOf(event.target as HTMLButtonElement)
        const next =
          event.key === 'ArrowUp'
            ? index - 1
            : event.key === 'ArrowDown'
              ? index + 1
              : event.key === 'Home'
                ? 0
                : event.key === 'End'
                  ? buttons.length - 1
                  : undefined
        if (next !== undefined) {
          event.preventDefault()
          buttons[Math.max(0, Math.min(next, buttons.length - 1))]?.focus()
        }
      }}>
      <div ref={ticks} className="pod-chat-turn-ticks" onScroll={() => setHover(undefined)}>
        {turns.map((turn, index) => (
          <button
            key={turn.id}
            type="button"
            data-turn-id={turn.id}
            tabIndex={index === tabStop ? 0 : -1}
            aria-label={t('pod.chat_timeline.jump_to_turn', { number: index + 1, text: turn.text.slice(0, 80) })}
            aria-current={visible.has(turn.id) ? 'location' : undefined}
            onPointerEnter={event => point(index, event.currentTarget)}
            onFocus={event => point(index, event.currentTarget)}
            onClick={() => jump(turn.id)}>
            <span
              className="pod-chat-turn-tick"
              style={{
                transform: `scaleX(${hover == null ? 0.24 : [1, 0.78, 0.55, 0.38][Math.min(3, Math.abs(index - hover.index))]})`
              }}
            />
          </button>
        ))}
      </div>
      {hover && (
        <div className="pod-chat-turn-preview" style={{ top: hover.top }} aria-hidden>
          <button type="button" tabIndex={-1} onClick={() => jump(turns[hover.index]!.id)}>
            <strong>{turns[hover.index]!.text}</strong>
            {turns[hover.index]!.preview && <span>{turns[hover.index]!.preview!.slice(0, 300)}</span>}
          </button>
        </div>
      )}
    </nav>
  )
}
