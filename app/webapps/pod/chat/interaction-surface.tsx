import { Badge, Button, cn } from '@ankole/uikit'
import type { ActionBinding, Spec, StateStore } from '@json-render/core'
import { JSONUIProvider, Renderer, useBoundProp, type ComponentRenderProps } from '@json-render/react'
import {
  CaretRightFilled,
  CheckmarkRegular,
  DismissRegular,
  DocumentTextRegular,
  ErrorCircleRegular,
  QuestionCircleRegular,
  ShieldKeyholeRegular
} from '@ankole/uikit/icons'
import { Link } from '@tanstack/react-router'
import { createContext, useContext, type ReactNode, type Ref } from 'react'
import { BdiLabel } from '../../common/bidi-file-name'
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
    /** The decision this button stands for is in flight, so the button itself shows the wait. */
    busy?: boolean
  }
  Outcome: {
    text: string
    icon?: 'check' | 'close' | 'warning'
    avatar?: string
    live?: boolean
    warning?: boolean
    /** The outcome was decided while the card was on screen, so it arrives instead of being there. */
    fresh?: boolean
  }
  Group: { kind: keyof typeof GROUPS }
  PageLink: { pageID: string; label: string }
  Line: { text: string }
  Disclosure: { title: string; text: string; open?: boolean; tall?: boolean }
}

type Rendered<K extends keyof InteractionElements> = ComponentRenderProps<InteractionElements[K]>

const ICONS = { check: CheckmarkRegular, close: DismissRegular, warning: ErrorCircleRegular }
const GROUPS = {
  compose: 'pod-chat-choice-compose',
  actions: 'flex flex-wrap items-center gap-2',
  details: 'pod-chat-choice-details',
  drafts: 'grid min-w-0 gap-2'
}

/** Lets the card's owner reach the card element, to move focus inside it and to tell whether it is on screen. */
const CardRef = createContext<Ref<HTMLDivElement> | undefined>(undefined)

function InteractionCard({ element: { props }, children }: Rendered<'InteractionCard'>) {
  const ref = useContext(CardRef)
  const Icon = props.kind === 'approval' ? ShieldKeyholeRegular : QuestionCircleRegular
  return (
    <div
      ref={ref}
      className={cn('pod-chat-choice-card', props.muted && 'pod-chat-choice-superseded')}
      data-testid={props.testid}
      data-action-kind={props.actionKind}
      data-state={props.state}>
      <div className="pod-chat-choice-header">
        <Icon aria-hidden />
        <span>{props.title}</span>
        {props.badge && <Badge variant={props.badge.variant}>{props.badge.text}</Badge>}
      </div>
      {children}
    </div>
  )
}

function Choice({ element: { props }, emit }: Rendered<'Choice'>) {
  return (
    <Button
      variant="ghost"
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
      disabled={props.disabled && !props.busy}
      loading={props.busy}
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
      data-fresh={props.fresh || undefined}
      data-tone={props.warning ? 'warning' : undefined}
      className="pod-chat-choice-outcome">
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
    <div className="flex min-w-0 items-center gap-1">
      <DocumentTextRegular className="size-5 shrink-0 text-fg-tertiary" aria-hidden />
      <Link className="link truncate" to={pageHref(props.pageID)}>
        {props.label}
      </Link>
    </div>
  )
}

/** A draft that the card carries, such as a diff or a complete document: a block card that opens like a step list. */
function Disclosure({ element: { props } }: Rendered<'Disclosure'>) {
  return (
    <details open={props.open} className="pod-chat-block-card">
      <summary className="pod-chat-block-card-header">
        <CaretRightFilled className="pod-chat-disclosure-caret" aria-hidden />
        <span>{props.title}</span>
      </summary>
      <pre className={cn('pod-chat-block-card-source', props.tall ? 'max-h-96' : 'max-h-72')}>{props.text}</pre>
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
  Disclosure
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
