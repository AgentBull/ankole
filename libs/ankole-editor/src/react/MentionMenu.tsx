import { RiAtLine, RiFileTextLine, RiUser3Line } from '@remixicon/react'
import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Wordgard } from '../core/editor'
import { GardState, Transaction } from '../core/state'
import { editorHost, type MentionItem } from '../editor/host-context'
import {
  commitMention,
  dismissMentionEffect,
  mentionField,
  reportMentionMatchesEffect,
  setMentionCategoryEffect,
  type MentionCategory
} from '../editor/mention'
import { useAnchoredOverlay } from './anchored-overlay'
import { useEditor, useEditorLabel, useEditorState } from './context'

const categories: readonly MentionCategory[] = ['all', 'page', 'principal']

type Controller = {
  onKeyDown(event: KeyboardEvent): boolean
  activeId(): string | null
  listId(): string | null
}

const controllers = new WeakMap<Wordgard, Controller>()

const keys = Wordgard.domEventHandler('keydown', (event, wg) => controllers.get(wg)?.onKeyDown(event) ?? false)

export const mentionMenu: GardState.Extension = [
  GardState.prec.highest(keys),
  Wordgard.contentAttributes.of((wg): Record<string, string | null> => {
    const controller = wg.hasFocus ? controllers.get(wg) : undefined
    const listId = controller?.listId() ?? null
    if (!listId) return {}
    return {
      'aria-controls': listId,
      'aria-activedescendant': controller?.activeId() ?? null
    }
  })
]

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function renderHighlightedTitle(title: string, query: string): ReactNode {
  const needle = query.trim()
  if (!needle) return title
  const match = new RegExp(escapeRegExp(needle), 'i').exec(title)
  if (!match || match[0].length === 0) return title
  const start = match.index
  const end = start + match[0].length
  return (
    <>
      {start > 0 && title.slice(0, start)}
      <mark className="mention-match">{title.slice(start, end)}</mark>
      {end < title.length && title.slice(end)}
    </>
  )
}

function optionKey(item: MentionItem): string {
  return 'page' in item.target ? `page:${item.target.page}` : `principal:${item.target.principal}`
}

export function MentionMenu() {
  const label = useEditorLabel()
  const editor = useEditor()
  const session = useEditorState(state => (editor.hasFocus ? (state.field(mentionField, false) ?? null) : null))
  const host = editorHost(editor)
  const enabled = Boolean(session && host?.queryMentions)
  const panelRef = useRef<HTMLDivElement>(null)

  const [state, setState] = useState<{
    category: MentionCategory
    query: string
    items: readonly MentionItem[]
    loading: boolean
  }>({
    category: 'all',
    query: '',
    items: [],
    loading: false
  })
  const [index, setIndex] = useState(0)

  const queryMentions = host?.queryMentions
  const activeQuery = session?.query ?? ''
  const activeCategory = session?.category ?? 'all'

  useEffect(() => {
    if (!enabled || !queryMentions) {
      setState(prev =>
        prev.items.length === 0 && !prev.loading ? prev : { category: 'all', query: '', items: [], loading: false }
      )
      setIndex(0)
      return
    }
    const controller = new AbortController()
    let maybePromise: ReturnType<typeof queryMentions>
    try {
      maybePromise = queryMentions({
        query: activeQuery,
        category: activeCategory,
        signal: controller.signal
      })
    } catch {
      setState({ category: activeCategory, query: activeQuery, items: [], loading: false })
      setIndex(0)
      return
    }

    const applyResult = (result: Awaited<ReturnType<typeof queryMentions>>) => {
      if (controller.signal.aborted) return
      setState({
        category: activeCategory,
        query: activeQuery,
        items: result.items,
        loading: false
      })
      setIndex(0)
      const totalAllMatches = result.totalAllMatches ?? (activeCategory === 'all' ? result.items.length : undefined)
      if (totalAllMatches !== undefined) {
        const current = editor.state.field(mentionField, false)
        if (current && current.query === activeQuery) {
          editor.dispatch({
            effects: reportMentionMatchesEffect.of({ query: activeQuery, totalAllMatches }),
            annotations: Transaction.addToHistory.of(false)
          })
        }
      }
    }

    if (maybePromise instanceof Promise) {
      setState(prev => ({
        category: activeCategory,
        query: activeQuery,
        // Keep matching previous items visible while fetching to avoid flicker on fast typing.
        items:
          prev.category === activeCategory && activeQuery.toLowerCase().startsWith(prev.query.toLowerCase())
            ? prev.items.filter(
                item => !activeQuery.trim() || item.title.toLowerCase().includes(activeQuery.trim().toLowerCase())
              )
            : [],
        loading: true
      }))
      setIndex(0)
      void maybePromise.then(applyResult, () => {
        if (!controller.signal.aborted) {
          setState({ category: activeCategory, query: activeQuery, items: [], loading: false })
          setIndex(0)
        }
      })
    } else {
      applyResult(maybePromise)
    }

    return () => controller.abort()
  }, [enabled, queryMentions, activeQuery, activeCategory, editor])

  const displayedItems = useMemo(() => {
    if (!enabled) return []
    if (state.category === activeCategory && state.query === activeQuery) return state.items
    if (state.category === activeCategory && activeQuery.toLowerCase().startsWith(state.query.toLowerCase())) {
      const needle = activeQuery.trim().toLowerCase()
      return needle ? state.items.filter(item => item.title.toLowerCase().includes(needle)) : state.items
    }
    return []
  }, [enabled, state, activeCategory, activeQuery])

  const loading = enabled && (state.loading || state.category !== activeCategory || state.query !== activeQuery)
  const clampedIndex = displayedItems.length > 0 ? Math.min(index, displayedItems.length - 1) : 0
  const listId = `${editor.contentDOM.id}-mention`
  const optionId = (i: number) => `${editor.contentDOM.id}-mention-${i}`

  const latest = useRef({
    displayedItems,
    clampedIndex,
    loading,
    listId,
    hasQuery: Boolean(queryMentions)
  })
  latest.current = {
    displayedItems,
    clampedIndex,
    loading,
    listId,
    hasQuery: Boolean(queryMentions)
  }

  useLayoutEffect(() => {
    const controller: Controller = {
      listId: () => {
        const liveSession = editor.hasFocus && latest.current.hasQuery ? editor.state.field(mentionField, false) : null
        return liveSession ? latest.current.listId : null
      },
      activeId: () => {
        const liveSession = editor.hasFocus && latest.current.hasQuery ? editor.state.field(mentionField, false) : null
        return liveSession && latest.current.displayedItems.length > 0 ? optionId(latest.current.clampedIndex) : null
      },
      onKeyDown(event) {
        const cur = latest.current
        const liveSession = editor.hasFocus && cur.hasQuery ? (editor.state.field(mentionField, false) ?? null) : null
        if (!liveSession) return false
        if (event.isComposing || event.keyCode === 229 || editor.composing) return false
        if (event.ctrlKey || event.metaKey || event.altKey) return false

        if (event.key === 'Tab') {
          event.preventDefault()
          const step = event.shiftKey ? -1 : 1
          const next =
            categories[(categories.indexOf(liveSession.category) + step + categories.length) % categories.length]!
          editor.dispatch({
            effects: setMentionCategoryEffect.of(next),
            annotations: Transaction.addToHistory.of(false)
          })
          return true
        }

        if (event.key === 'Escape') {
          event.preventDefault()
          editor.dispatch({
            effects: dismissMentionEffect.of(null),
            annotations: Transaction.addToHistory.of(false)
          })
          return true
        }

        if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !event.shiftKey) {
          const count = cur.displayedItems.length
          if (!count) return cur.loading
          event.preventDefault()
          const step = event.key === 'ArrowDown' ? 1 : -1
          setIndex(prev => (Math.min(prev, count - 1) + step + count) % count)
          return true
        }

        if (event.key === 'Enter' && !event.shiftKey) {
          const chosen = cur.displayedItems[cur.clampedIndex]
          if (chosen) {
            event.preventDefault()
            commitMention(editor, chosen.target)
            return true
          }
          if (cur.loading) {
            event.preventDefault()
            return true
          }
          editor.dispatch({
            effects: dismissMentionEffect.of(null),
            annotations: Transaction.addToHistory.of(false)
          })
          return false
        }

        return false
      }
    }
    controllers.set(editor, controller)
    return () => {
      if (controllers.get(editor) === controller) controllers.delete(editor)
    }
  }, [editor])

  const from = session?.from
  const position = useAnchoredOverlay({
    open: enabled,
    panelRef,
    anchor: () => (from === undefined ? null : editor.coordsAtPos(from, 1)),
    onClose: () =>
      editor.dispatch({
        effects: dismissMentionEffect.of(null),
        annotations: Transaction.addToHistory.of(false)
      }),
    dependencies: [from, activeCategory, displayedItems.length, loading]
  })

  useLayoutEffect(() => {
    if (enabled && displayedItems.length > 0) {
      panelRef.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
    }
  }, [enabled, clampedIndex, displayedItems.length])

  if (!enabled || !session) return null

  const tabLabels: Record<MentionCategory, string> = {
    all: label('mention_tab_all'),
    page: label('mention_tab_page'),
    principal: label('mention_tab_principal')
  }

  return createPortal(
    <div
      ref={panelRef}
      className="mention-menu ankole-editor-overlay ceramic ceramic-primary"
      aria-label={label('mention_menu')}
      style={position ?? { visibility: 'hidden' }}>
      <div className="mention-tabs" role="tablist" aria-label={label('mention_menu')}>
        {categories.map(cat => (
          <button
            key={cat}
            type="button"
            role="tab"
            tabIndex={-1}
            className="mention-tab"
            aria-selected={session.category === cat}
            onMouseDown={event => event.preventDefault()}
            onClick={() => {
              editor.dispatch({
                effects: setMentionCategoryEffect.of(cat),
                annotations: Transaction.addToHistory.of(false)
              })
              editor.focus()
            }}>
            {tabLabels[cat]}
          </button>
        ))}
        <span className="mention-tab-hint" aria-hidden="true">
          {label('mention_tab_hint')}
        </span>
      </div>
      <div id={listId} className="mention-list" role="listbox" aria-label={tabLabels[session.category]}>
        {displayedItems.length > 0 ? (
          displayedItems.map((item, idx) => {
            const showSection = Boolean(item.section && item.section !== displayedItems[idx - 1]?.section)
            return (
              <Fragment key={optionKey(item)}>
                {showSection && (
                  <div
                    role="presentation"
                    className={
                      item.sectionCategory ? 'mention-group-label mention-group-clickable' : 'mention-group-label'
                    }
                    onMouseDown={item.sectionCategory ? event => event.preventDefault() : undefined}
                    onClick={
                      item.sectionCategory
                        ? () => {
                            editor.dispatch({
                              effects: setMentionCategoryEffect.of(item.sectionCategory!),
                              annotations: Transaction.addToHistory.of(false)
                            })
                            editor.focus()
                          }
                        : undefined
                    }>
                    {item.section}
                  </div>
                )}
                <button
                  id={optionId(idx)}
                  type="button"
                  role="option"
                  tabIndex={-1}
                  className="mention-option"
                  aria-selected={idx === clampedIndex}
                  onMouseDown={event => event.preventDefault()}
                  onMouseEnter={() => {
                    if (clampedIndex !== idx) setIndex(idx)
                  }}
                  onClick={() => commitMention(editor, item.target)}>
                  <span className="mention-option-icon" aria-hidden="true">
                    {item.icon ?? ('page' in item.target ? <RiFileTextLine /> : <RiUser3Line />)}
                  </span>
                  <span className="mention-option-body">
                    <span className="mention-option-title-row">
                      <span className="mention-option-title">{renderHighlightedTitle(item.title, session.query)}</span>
                      {item.badge && <span className="mention-option-badge">{item.badge}</span>}
                    </span>
                    {item.subtitle && <span className="mention-option-subtitle">{item.subtitle}</span>}
                  </span>
                </button>
              </Fragment>
            )
          })
        ) : (
          <div className="mention-empty" role="status">
            <RiAtLine aria-hidden="true" />
            <span>{label(loading ? 'mention_loading' : 'mention_empty')}</span>
          </div>
        )}
      </div>
    </div>,
    document.body
  )
}
