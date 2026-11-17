import { Button } from '@ankole/uikit/components/button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuTrigger } from '@ankole/uikit/components/dropdown-menu'
import {
  BotRegular,
  ChevronDownRegular,
  CodeRegular,
  CommentRegular,
  HighlightRegular,
  LinkRegular,
  MathFormulaRegular,
  TextBoldRegular,
  TextItalicRegular,
  TextStrikethroughRegular,
  TextUnderlineRegular
} from '@ankole/uikit/icons'
import type { RefObject } from 'react'
import { canInsertInlineMath, insertInlineMath, singleSelectedInlineMathPos } from '../blocks/math'
import type { PhraseSet } from '../core/phrases'
import type { GardState } from '../core/state'
import type { ResourceView } from '../document/resources'
import { blockTypeAt, canTurnInto, turnBlockInto } from '../editor/block-actions'
import { blockOptions, type BlockType } from '../editor/block-catalog'
import { selectedUnits } from '../editor/block-selection'
import type { FormatName } from '../editor/commands'
import { commentSelection, type CommentSelection } from '../editor/comments'
import { editorHost } from '../editor/host-context'
import { isKnowledge, knowledgeBlockTypes } from '../editor/knowledge'
import { availableLinkViews, inlineLinkView, isWebLink } from '../editor/link-views'
import type { LinkInfo } from '../editor/links'
import { editorPhrases } from '../editor/phrases'
import { BlockTypeItems } from './block-type-items'
import { useEditor, useEditorLabel, useEditorState } from './context'
import { LinkViewDropdown } from './link-view-menu'

// How the text looks. Highlight is a look of the text like the others, so it closes this group.
export const SELECTION_FORMAT_BUTTONS = [
  { format: 'strong', label: editorPhrases.ref('bold'), Icon: TextBoldRegular },
  { format: 'em', label: editorPhrases.ref('italic'), Icon: TextItalicRegular },
  { format: 'u', label: editorPhrases.ref('underline'), Icon: TextUnderlineRegular },
  { format: 's', label: editorPhrases.ref('strikethrough'), Icon: TextStrikethroughRegular },
  { format: 'code', label: editorPhrases.ref('inline_code'), Icon: CodeRegular },
  { format: 'mark', label: editorPhrases.ref('highlight'), Icon: HighlightRegular }
] satisfies { format: FormatName; label: PhraseSet.Ref; Icon: typeof TextBoldRegular }[]

export type PageMentionInfo = { id: string; from: number; to: number }

export type SelectionToolbarInfo = {
  rect: DOMRect
  active: boolean[]
  link: boolean
  selectedLink: LinkInfo | null
  caretLink: LinkInfo | null
  caretMention: PageMentionInfo | null
}

/** Whether every block the selection touches can turn into another type. */
function canTurnSelection(state: GardState) {
  const units = selectedUnits(state)
  return !!units?.length && units.every(unit => canTurnInto(state, unit.before))
}

/** The block type every block the selection touches shares, or null when they differ. */
function sharedBlockType(state: GardState): BlockType | null {
  const types = new Set(selectedUnits(state)?.map(unit => blockTypeAt(state, unit.before)))
  return types.size === 1 ? [...types][0]! : null
}

/**
 * The selection toolbar groups its actions by the question each answers, in this order: who helps with the
 * text (ask an Agent), what the blocks are (block type), how the text looks (marks), and what the text
 * connects to (link, comment, link view). Read-only documents and code keep only the actions that leave the
 * text as it is: asking an Agent and commenting.
 */
export function SelectionActions({
  editable,
  info,
  apply,
  openLink,
  switchInlineView,
  unfurling,
  hide,
  typeMenu,
  viewMenu,
  onViewMenuOpenChange
}: {
  editable: boolean
  info: SelectionToolbarInfo
  apply(format: FormatName): void
  openLink(): boolean
  switchInlineView(target: LinkInfo, nextView: ResourceView): Promise<void>
  unfurling: boolean
  hide(): void
  typeMenu: RefObject<HTMLDivElement | null>
  viewMenu: RefObject<HTMLDivElement | null>
  onViewMenuOpenChange(open: boolean): void
}) {
  const label = useEditorLabel()
  const editor = useEditor()
  const state = useEditorState()
  const host = editorHost(editor)
  // A native selection can be newer than the editor's last animation frame.
  const handOff = (action: (selection: CommentSelection) => void) => {
    editor.flush()
    const selection = commentSelection(editor)
    if (selection) action(selection)
    hide()
  }
  const askAgent = host?.askAgent
  const requestComment = isKnowledge(state) ? undefined : host?.requestComment
  const type = sharedBlockType(state)
  const selectedLink = editable && info.selectedLink && isWebLink(info.selectedLink.href) ? info.selectedLink : null
  const activeSelectedView =
    selectedLink && selectedLink.to <= state.doc.length ? inlineLinkView(state, selectedLink) : 'link'
  const linkViews = selectedLink ? availableLinkViews(state) : []
  return (
    <>
      {askAgent && (
        <div role="group" className="selection-group">
          <Button
            variant="ghost"
            size="sm"
            className="selection-ask"
            aria-label={label('ask_agent')}
            title={label('ask_agent')}
            onMouseDown={event => event.preventDefault()}
            onClick={() => handOff(askAgent)}>
            <BotRegular aria-hidden="true" />
            <span className="selection-ask-label">{label('ask_agent')}</span>
          </Button>
        </div>
      )}
      {editable && canTurnSelection(state) && (
        <div role="group" className="selection-group">
          <DropdownMenu modal={false}>
            <DropdownMenuTrigger
              onMouseDown={event => event.preventDefault()}
              render={
                <Button
                  variant="ghost"
                  size="sm"
                  className="selection-block-type"
                  aria-label={label('turn_into_type')}
                  title={label('turn_into_type')}
                />
              }>
              <span className="selection-block-type-label">
                {type ? blockOptions.find(option => option.type === type)?.title(state) : label('turn_into')}
              </span>
              <ChevronDownRegular aria-hidden="true" />
            </DropdownMenuTrigger>
            <DropdownMenuContent
              ref={typeMenu}
              className="block-menu ankole-editor-overlay"
              aria-label={label('turn_into_type')}
              finalFocus={() => {
                editor.focus()
                return false
              }}>
              <BlockTypeItems
                options={blockOptions.filter(
                  option => option.turnInto && (!isKnowledge(state) || knowledgeBlockTypes.has(option.type))
                )}
                current={type}
                onChoose={next => turnBlockInto(editor, undefined, next)}
              />
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      )}
      {editable && (
        <div role="group" className="selection-group">
          {SELECTION_FORMAT_BUTTONS.map(
            ({ format, label: phrase, Icon }, index) =>
              (!isKnowledge(state) || !['u', 'mark'].includes(format)) && (
                <Button
                  key={format}
                  variant="ghost"
                  size="icon-sm"
                  aria-label={phrase(state)}
                  title={phrase(state)}
                  aria-pressed={info.active[index]}
                  onMouseDown={event => event.preventDefault()}
                  onClick={() => apply(format)}>
                  <Icon aria-hidden="true" />
                </Button>
              )
          )}
          {!isKnowledge(state) && canInsertInlineMath(state) && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={label('inline_math_title')}
              title={label('inline_math_title')}
              aria-pressed={singleSelectedInlineMathPos(state) !== null}
              onMouseDown={event => event.preventDefault()}
              onClick={() => insertInlineMath(editor)}>
              <MathFormulaRegular aria-hidden="true" />
            </Button>
          )}
        </div>
      )}
      {(editable || requestComment) && (
        <div role="group" className="selection-group">
          {editable && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={label('link')}
              title={label('link')}
              aria-pressed={info.link}
              onMouseDown={event => event.preventDefault()}
              onClick={openLink}>
              <LinkRegular aria-hidden="true" />
            </Button>
          )}
          {requestComment && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={label('comment')}
              title={label('comment')}
              onMouseDown={event => event.preventDefault()}
              onClick={() => handOff(requestComment)}>
              <CommentRegular aria-hidden="true" />
            </Button>
          )}
        </div>
      )}
      {selectedLink && (
        <div role="group" className="selection-group">
          <LinkViewDropdown
            editor={editor}
            current={activeSelectedView}
            views={linkViews}
            unfurling={unfurling}
            menuRef={viewMenu}
            onOpenChange={onViewMenuOpenChange}
            onSelect={viewOption => void switchInlineView(selectedLink, viewOption)}
          />
        </div>
      )}
    </>
  )
}
