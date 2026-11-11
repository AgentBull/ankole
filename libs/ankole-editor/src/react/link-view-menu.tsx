import { Button } from '@ankole/uikit/components/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@ankole/uikit/components/dropdown-menu'
import { Input } from '@ankole/uikit/components/input'
import { Spinner } from '@ankole/uikit/components/spinner'
import { composingKey } from '@ankole/uikit/lib/keyboard'
import {
  CheckmarkRegular,
  ChevronDownRegular,
  DismissRegular,
  EditRegular,
  LinkDismissRegular,
  LinkRegular,
  MentionRegular,
  PaymentRegular,
  TextTRegular,
  WindowRegular
} from '@ankole/uikit/icons'
import { useId, type KeyboardEvent, type RefObject } from 'react'
import type { Wordgard } from '../core/editor'
import type { ResourceView } from '../document/resources'
import { isWebLink } from '../editor/link-views'
import type { LinkInfo } from '../editor/links'
import { useEditorLabel } from './context'

export type LinkBarDescription = { display: string; title: string; editHref: string }

export function LinkViewIcon({ view }: { view: ResourceView }) {
  switch (view) {
    case 'link':
      return <LinkRegular aria-hidden="true" />
    case 'title':
      return <TextTRegular aria-hidden="true" />
    case 'card':
      return <PaymentRegular aria-hidden="true" />
    case 'preview':
      return <WindowRegular aria-hidden="true" />
  }
}

/** Roving horizontal arrow/Home/End focus navigation across interactive items inside a floating toolbar. */
export function rovingToolbarKeyDown(event: KeyboardEvent<HTMLElement>, selector = 'button, a[href]'): boolean {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return false
  const items = [...event.currentTarget.querySelectorAll<HTMLElement>(selector)]
  if (!items.length) return false
  const index = items.indexOf(document.activeElement as HTMLElement)
  const next =
    event.key === 'Home'
      ? 0
      : event.key === 'End'
        ? items.length - 1
        : (index + (event.key === 'ArrowRight' ? 1 : -1) + items.length) % items.length
  event.preventDefault()
  items[next]?.focus()
  return true
}

export function LinkViewDropdown({
  editor,
  current,
  views,
  unfurling = false,
  triggerClassName = 'link-view-trigger',
  menuRef,
  onOpenChange,
  onMenuPointerEnter,
  onMenuPointerLeave,
  onSelect
}: {
  editor: Wordgard
  current: ResourceView
  views: readonly ResourceView[]
  unfurling?: boolean
  triggerClassName?: string
  menuRef?: RefObject<HTMLDivElement | null>
  onOpenChange?: (open: boolean) => void
  onMenuPointerEnter?: () => void
  onMenuPointerLeave?: () => void
  onSelect: (view: ResourceView) => void
}) {
  const label = useEditorLabel()
  return (
    <DropdownMenu modal={false} onOpenChange={onOpenChange}>
      <DropdownMenuTrigger
        onMouseDown={event => event.preventDefault()}
        render={
          <Button
            variant="ghost"
            size="xs"
            className={triggerClassName}
            aria-label={label('resource_view')}
            disabled={unfurling}
          />
        }>
        {unfurling ? <Spinner aria-hidden="true" /> : <LinkViewIcon view={current} />}
        <span>{label(`resource_view_${current}`)}</span>
        <ChevronDownRegular aria-hidden="true" />
      </DropdownMenuTrigger>
      <DropdownMenuContent
        ref={menuRef}
        className="ankole-editor-overlay"
        aria-label={label('resource_view')}
        onPointerEnter={onMenuPointerEnter}
        onPointerLeave={onMenuPointerLeave}
        finalFocus={() => {
          editor.focus()
          return false
        }}>
        {views.map(viewOption => (
          <DropdownMenuItem key={viewOption} onClick={() => onSelect(viewOption)}>
            <LinkViewIcon view={viewOption} />
            <span>{label(`resource_view_${viewOption}`)}</span>
            {current === viewOption && <CheckmarkRegular className="ms-auto" aria-hidden="true" />}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export function LinkEditForm({
  canEditText,
  hasExistingLink,
  linkText,
  url,
  error,
  onChangeText,
  onChangeUrl,
  onSubmit,
  onCancel,
  onRemove
}: {
  canEditText: boolean
  hasExistingLink: boolean
  linkText: string
  url: string
  error: boolean
  onChangeText: (value: string) => void
  onChangeUrl: (value: string) => void
  onSubmit: () => void
  onCancel: () => void
  onRemove: () => void
}) {
  const label = useEditorLabel()
  const errorId = useId()
  return (
    <form
      className="link-form"
      onSubmit={event => {
        event.preventDefault()
        onSubmit()
      }}>
      {canEditText && (
        <div className="link-form-row">
          <Input
            variant="overlay"
            aria-label={label('link_text')}
            value={linkText}
            placeholder={label('link_text')}
            onChange={event => onChangeText(event.target.value)}
            onKeyDown={event => {
              if (event.key === 'Enter' && composingKey(event.nativeEvent)) event.preventDefault()
            }}
          />
        </div>
      )}
      <div className="link-form-row">
        <Input
          variant="overlay"
          autoFocus
          aria-label={label('link_address')}
          value={url}
          placeholder={label('link_placeholder')}
          autoCorrect="off"
          autoCapitalize="off"
          spellCheck={false}
          aria-invalid={error}
          aria-describedby={error ? errorId : undefined}
          onChange={event => onChangeUrl(event.target.value)}
          onKeyDown={event => {
            if (event.key === 'Enter' && composingKey(event.nativeEvent)) event.preventDefault()
          }}
        />
        <Button type="submit" size="xs">
          {label('apply_link')}
        </Button>
        <Button type="button" variant="ghost" size="icon-xs" aria-label={label('cancel_link')} onClick={onCancel}>
          <DismissRegular aria-hidden="true" />
        </Button>
      </div>
      {error && (
        <p id={errorId} role="alert">
          {label('invalid_link')}
        </p>
      )}
      {hasExistingLink && (
        <Button type="button" variant="ghost" size="xs" onClick={onRemove}>
          {label('remove_link')}
        </Button>
      )}
    </form>
  )
}

export function LinkFloatingBar({
  editor,
  link,
  display,
  activeView,
  views,
  unfurling,
  menuRef,
  onOpenLink,
  onEditLink,
  onRemoveLink,
  onSwitchView,
  onMenuOpenChange,
  onMenuPointerEnter,
  onMenuPointerLeave
}: {
  editor: Wordgard
  link: LinkInfo
  display: LinkBarDescription
  activeView: ResourceView
  views: readonly ResourceView[]
  unfurling: boolean
  menuRef: RefObject<HTMLDivElement | null>
  onOpenLink: () => void
  onEditLink: () => void
  onRemoveLink: () => void
  onSwitchView: (nextView: ResourceView) => void
  onMenuOpenChange: (open: boolean) => void
  onMenuPointerEnter: () => void
  onMenuPointerLeave: () => void
}) {
  const label = useEditorLabel()
  return (
    <div className="link-bar">
      <button
        type="button"
        className="link-bar-url"
        aria-label={label('open_link')}
        title={display.title}
        onMouseDown={event => event.preventDefault()}
        onClick={onOpenLink}>
        {display.display}
      </button>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={label('edit_link')}
        title={label('edit_link')}
        onMouseDown={event => event.preventDefault()}
        onClick={onEditLink}>
        <EditRegular aria-hidden="true" />
      </Button>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={label('remove_link')}
        title={label('remove_link')}
        onMouseDown={event => event.preventDefault()}
        onClick={onRemoveLink}>
        <LinkDismissRegular aria-hidden="true" />
      </Button>
      {isWebLink(link.href) && (
        <>
          <span className="toolbar-divider" aria-hidden="true" />
          <LinkViewDropdown
            editor={editor}
            current={activeView}
            views={views}
            unfurling={unfurling}
            menuRef={menuRef}
            onOpenChange={onMenuOpenChange}
            onMenuPointerEnter={onMenuPointerEnter}
            onMenuPointerLeave={onMenuPointerLeave}
            onSelect={onSwitchView}
          />
        </>
      )}
    </div>
  )
}

export function MentionFloatingBar({
  editor,
  display,
  canOpenPage,
  menuRef,
  onOpenPage,
  onEmbed,
  onMenuOpenChange
}: {
  editor: Wordgard
  display: LinkBarDescription
  canOpenPage: boolean
  menuRef: RefObject<HTMLDivElement | null>
  onOpenPage: () => void
  onEmbed: () => void
  onMenuOpenChange: (open: boolean) => void
}) {
  const label = useEditorLabel()
  return (
    <div className="link-bar">
      {canOpenPage && (
        <>
          <button
            type="button"
            className="link-bar-url"
            aria-label={label('open_page')}
            title={display.title}
            onMouseDown={event => event.preventDefault()}
            onClick={onOpenPage}>
            {display.display}
          </button>
          <span className="toolbar-divider" aria-hidden="true" />
        </>
      )}
      <DropdownMenu modal={false} onOpenChange={onMenuOpenChange}>
        <DropdownMenuTrigger
          onMouseDown={event => event.preventDefault()}
          render={
            <Button variant="ghost" size="xs" className="link-view-trigger" aria-label={label('resource_view')} />
          }>
          <MentionRegular aria-hidden="true" />
          <span>{label('mention_view_inline')}</span>
          <ChevronDownRegular aria-hidden="true" />
        </DropdownMenuTrigger>
        <DropdownMenuContent
          ref={menuRef}
          className="ankole-editor-overlay"
          aria-label={label('resource_view')}
          finalFocus={() => {
            editor.focus()
            return false
          }}>
          <DropdownMenuItem>
            <MentionRegular aria-hidden="true" />
            <span>{label('mention_view_inline')}</span>
            <CheckmarkRegular className="ms-auto" aria-hidden="true" />
          </DropdownMenuItem>
          <DropdownMenuItem onClick={onEmbed}>
            <WindowRegular aria-hidden="true" />
            <span>{label('mention_view_embed')}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  )
}
