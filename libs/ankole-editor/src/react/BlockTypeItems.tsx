import { DropdownMenuItem } from '@ankole/uikit/components/dropdown-menu'
import { RiCheckLine } from '@remixicon/react'
import { Fragment } from 'react'
import type { BlockOption, BlockType } from '../editor/block-catalog'
import { BlockTypeIcon, blockMenuGroup } from './block-type-icon'
import { useEditor, useEditorLabel } from './context'

/** One block catalogue view; slash keeps focus in the editor, pointer menus use menu-item focus. */
export function BlockTypeItems({
  options,
  onChoose,
  current,
  slash
}: {
  options: readonly BlockOption[]
  onChoose(type: BlockType): void
  current?: BlockType | null
  slash?: { index: number; id(index: number): string; highlight(index: number): void }
}) {
  const editor = useEditor()
  const label = useEditorLabel()
  return options.map((option, index) => {
    const title = option.title(editor.state)
    const detail = option.detail(editor.state)
    const content = (
      <>
        <span className="block-type-slot">
          <BlockTypeIcon type={option.type} />
        </span>
        <span title={detail}>{title}</span>
        {current === option.type && <RiCheckLine className="block-type-current" aria-hidden />}
      </>
    )
    return (
      <Fragment key={option.type}>
        {(index === 0 || blockMenuGroup(option.type) !== blockMenuGroup(options[index - 1]!.type)) && (
          <div className="menu-label" role="presentation">
            {label(blockMenuGroup(option.type))}
          </div>
        )}
        {slash ? (
          <button
            id={slash.id(index)}
            type="button"
            tabIndex={-1}
            className="block-type-option"
            role="option"
            aria-selected={index === slash.index}
            aria-description={detail}
            onMouseDown={event => event.preventDefault()}
            onMouseEnter={() => slash.highlight(index)}
            onClick={() => onChoose(option.type)}>
            {content}
          </button>
        ) : (
          <DropdownMenuItem
            className="block-type-option"
            data-current={current === option.type}
            aria-current={current === option.type ? 'true' : undefined}
            aria-description={detail}
            onClick={() => onChoose(option.type)}>
            {content}
          </DropdownMenuItem>
        )}
      </Fragment>
    )
  })
}
