import { Badge, Button, cn } from '@ankole/uikit'
import type { ActionBinding, Spec, StateStore } from '@json-render/core'
import { JSONUIProvider, Renderer, useBoundProp, type ComponentRenderProps } from '@json-render/react'
import {
  RiArrowRightSLine,
  RiCheckLine,
  RiCloseLine,
  RiErrorWarningLine,
  RiFileTextLine,
  RiQuestionLine,
  RiShieldKeyholeLine
} from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import { createContext, useContext, type ReactNode, type Ref } from 'react'
import { BdiLabel } from '../../common/bidi-file-name'
import type { PageSharingExplain } from '../content-api'
import { AccessWaterfallView } from '../page-sharing/access-waterfall-view'
import { usePageHref } from '../use-page-metadata'
import { ClarifyFieldControl, type ClarifyFieldProps } from './clarify-form'
import { useLatestHandlers, type ActionHandlers } from './ui-block/use-latest-handlers'

type Bound = { $bindState: string }

/**
 * The elements of Ankole's own interaction specs: the Clarify card and the Action Card. Pod builds these specs
 * from what the control plane committed, and their actions call the control plane, which owns the answer and
 * the approval. A model-written `ui` block renders from its own catalog and cannot reach these elements.
 */
export type InteractionElements = {
  InteractionCard: {
    kind: 'question' | 'approval'
    title: string
    state: string
    muted?: boolean
    badge?: { text: string; variant: 'secondary' | 'destructive' | 'outline' }
    testid?: string
    actionKind?: string
  }
  Question: { text: string; bidi?: boolean }
  Choices: Record<string, never>
  Choice: { label: string; description?: string | null; shortcut?: string; pressed: boolean; disabled: boolean }
  QuickAnswer: { label: string; placeholder: string; submit: string; value: Bound; disabled: boolean }
  Form: Record<string, never>
  FormField: Omit<ClarifyFieldProps, 'value' | 'error' | 'edited'> & { value: Bound; error: Bound; edited: Bound }
  ActionButton: {
    label: string
    variant: 'default' | 'outline' | 'ghost' | 'destructive'
    size: 'sm' | 'xs'
    icon?: 'check' | 'close'
    /** Submits the enclosing Form instead of emitting `press`. */
    submit?: boolean
    disabled: boolean
  }
  Outcome: { text: string; icon?: 'check' | 'close' | 'warning'; avatar?: string; live?: boolean; warning?: boolean }
  Group: { kind: keyof typeof GROUPS }
  PageLink: { pageID: string; label: string }
  Line: { text: string }
  Disclosure: { title: string; text: string; open?: boolean; tall?: boolean }
  WaterfallDisclosure: { title: string; explain: PageSharingExplain; open?: boolean }
}

type Rendered<K extends keyof InteractionElements> = ComponentRenderProps<InteractionElements[K]>

const ICONS = { check: RiCheckLine, close: RiCloseLine, warning: RiErrorWarningLine }
const GROUPS = {
  compose: 'pod-chat-choice-compose',
  actions: 'flex flex-wrap items-center gap-2 px-3.5 pb-3',
  details:
    'mx-3.5 mb-3 space-y-1.5 rounded-control border border-border bg-muted/35 px-3 py-2 text-xs text-fg-secondary',
  drafts: 'mx-3.5 mb-3 min-w-0 space-y-2'
}

/** Lets the card's owner reach the card element, to move focus inside it and to tell whether it is on screen. */
const CardRef = createContext<Ref<HTMLDivElement> | undefined>(undefined)

function InteractionCard({ element: { props }, children }: Rendered<'InteractionCard'>) {
  const ref = useContext(CardRef)
  const Icon = props.kind === 'approval' ? RiShieldKeyholeLine : RiQuestionLine
  return (
    <div
      ref={ref}
      className={cn('pod-chat-choice-card', props.muted && 'pod-chat-choice-superseded')}
      data-testid={props.testid}
      data-action-kind={props.actionKind}
      data-state={props.state}>
      {props.badge ? (
        <div className="pod-chat-choice-header justify-between">
          <span className="inline-flex items-center gap-1.5">
            <Icon aria-hidden />
            <span>{props.title}</span>
          </span>
          <Badge variant={props.badge.variant}>{props.badge.text}</Badge>
        </div>
      ) : (
        <div className="pod-chat-choice-header">
          <Icon aria-hidden />
          <span>{props.title}</span>
        </div>
      )}
      {children}
    </div>
  )
}

function Choice({ element: { props }, emit }: Rendered<'Choice'>) {
  return (
    <Button
      variant="outline"
      className="pod-chat-choice"
      disabled={props.disabled}
      aria-keyshortcuts={props.shortcut}
      aria-pressed={props.pressed}
      onClick={() => emit('press')}>
      <span>
        <strong>{props.label}</strong>
        {props.description && <small>{props.description}</small>}
      </span>
      {props.shortcut && <kbd>{props.shortcut}</kbd>}
    </Button>
  )
}

function QuickAnswer({ element: { props }, bindings, emit }: Rendered<'QuickAnswer'>) {
  const [value, setValue] = useBoundProp<unknown>(props.value, bindings?.value)
  const text = typeof value === 'string' ? value : ''
  return (
    <form
      className="pod-chat-choice-custom"
      onSubmit={event => {
        event.preventDefault()
        if (!props.disabled && text.trim()) emit('submit')
      }}>
      <input
        aria-label={props.label}
        placeholder={props.placeholder}
        value={text}
        disabled={props.disabled}
        onChange={event => setValue(event.currentTarget.value)}
      />
      <Button type="submit" size="xs" variant="ghost" disabled={props.disabled || !text.trim()}>
        {props.submit}
      </Button>
    </form>
  )
}

function ActionButton({ element: { props }, emit }: Rendered<'ActionButton'>) {
  const Icon = props.icon && ICONS[props.icon]
  return (
    <Button
      type={props.submit ? 'submit' : 'button'}
      size={props.size}
      variant={props.variant}
      disabled={props.disabled}
      onClick={props.submit ? undefined : () => emit('press')}>
      {Icon && <Icon aria-hidden />}
      {props.label}
    </Button>
  )
}

function Outcome({ element: { props } }: Rendered<'Outcome'>) {
  const Icon = props.icon && ICONS[props.icon]
  return (
    <p
      role={props.live ? 'status' : undefined}
      className={cn('pod-chat-choice-outcome', props.warning && 'text-warning-foreground')}>
      {Icon && <Icon aria-hidden />}
      {props.avatar && (
        <span className="pod-chat-event-avatar" aria-hidden>
          {props.avatar}
        </span>
      )}
      {Icon ? <span>{props.text}</span> : props.text}
    </p>
  )
}

function PageLink({ element: { props } }: Rendered<'PageLink'>) {
  const pageHref = usePageHref()
  return (
    <div className="flex items-center gap-1.5">
      <RiFileTextLine className="size-3.5 shrink-0 text-fg-tertiary" aria-hidden />
      <Link className="truncate font-medium text-foreground hover:underline" to={pageHref(props.pageID)}>
        {props.label}
      </Link>
    </div>
  )
}

function Disclosure({ element: { props } }: Rendered<'Disclosure'>) {
  return (
    <details open={props.open} className="code-surface group">
      <summary className="code-toolbar cursor-pointer px-3 py-2 text-xs font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">
        <RiArrowRightSLine className="size-3.5 shrink-0 group-open:rotate-90" aria-hidden />
        {props.title}
      </summary>
      <pre
        className={cn(
          'code-text overflow-auto whitespace-pre-wrap break-words px-3 py-2 text-xs',
          props.tall ? 'max-h-96' : 'max-h-72'
        )}>
        {props.text}
      </pre>
    </details>
  )
}

function WaterfallDisclosure({ element: { props } }: Rendered<'WaterfallDisclosure'>) {
  return (
    <details open={props.open} className="code-surface group">
      <summary className="code-toolbar cursor-pointer px-3 py-2 text-xs font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">
        <RiArrowRightSLine className="size-3.5 shrink-0 group-open:rotate-90" aria-hidden />
        {props.title}
      </summary>
      <div className="p-3">
        <AccessWaterfallView explain={props.explain} compact />
      </div>
    </details>
  )
}

const registry: { [K in keyof InteractionElements]: (props: Rendered<K>) => ReactNode } = {
  InteractionCard,
  Question: ({ element: { props } }) => (
    <p className="pod-chat-choice-question">
      {props.bidi ? <BdiLabel value={props.text} showBidiWarning={false} /> : props.text}
    </p>
  ),
  Choices: ({ children }) => <div className="pod-chat-choices">{children}</div>,
  Choice,
  QuickAnswer,
  Form: ({ children, emit }) => (
    <form
      className="pod-chat-choice-form"
      noValidate
      onSubmit={event => {
        event.preventDefault()
        emit('submit')
      }}>
      {children}
    </form>
  ),
  FormField: ClarifyFieldControl as (props: Rendered<'FormField'>) => ReactNode,
  ActionButton,
  Outcome,
  Group: ({ element: { props }, children }) => <div className={GROUPS[props.kind]}>{children}</div>,
  PageLink,
  Line: ({ element: { props } }) => <div className="break-words">{props.text}</div>,
  Disclosure,
  WaterfallDisclosure
}

type Children = (string | false | null | undefined)[]

/** Collects the elements of an interaction spec under stable keys, so an element keeps its state across rebuilds. */
export function interactionSpec() {
  const elements: Spec['elements'] = {}
  return {
    /** Adds one element and returns its key; falsy children are left out. */
    add<K extends keyof InteractionElements>(
      key: string,
      type: K,
      props: InteractionElements[K],
      children: Children = [],
      on?: Record<string, ActionBinding>
    ) {
      elements[key] = { type, props, children: children.filter(child => !!child) as string[], ...(on && { on }) }
      return key
    },
    spec: (root: string): Spec => ({ root, elements })
  }
}

/** Renders an interaction spec. `store` holds the card's draft when its owner reads or writes that draft. */
export function InteractionSurface({
  spec,
  store,
  handlers,
  cardRef
}: {
  spec: Spec
  store?: StateStore
  handlers: ActionHandlers
  cardRef?: Ref<HTMLDivElement>
}) {
  return (
    <CardRef.Provider value={cardRef}>
      <JSONUIProvider registry={registry} store={store} handlers={useLatestHandlers(handlers)}>
        <Renderer spec={spec} registry={registry} />
      </JSONUIProvider>
    </CardRef.Provider>
  )
}
