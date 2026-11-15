import { DropdownMenuItem } from '@ankole/uikit/components/dropdown-menu'
import { MenuRichItem } from '@ankole/uikit/components/menu'
import { CheckmarkRegular } from '@ankole/uikit/icons'
import { Fragment } from 'react'
import type { BlockOption, BlockType } from '../editor/block-catalog'
import { BlockTypeIcon, blockMenuGroup } from './block-type-icon'
import { useEditor, useEditorLabel } from './context'

/**
 * One view of the block catalogue under its group titles. The slash menu keeps focus in the editor and lays each
 * block type on a rich row with its tile; the insert and turn-into menus are plain menus whose rows take menu-item
 * focus and mark the current type with a check.
 */
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
    return (
      <Fragment key={option.type}>
        {(index === 0 || blockMenuGroup(option.type) !== blockMenuGroup(options[index - 1]!.type)) && (
          // The slash menu's rows run from edge to edge with their tiles 8px in, so its titles start there too.
          <div className={slash ? 'menu-group-label px-2' : 'menu-group-label'} role="presentation">
            {label(blockMenuGroup(option.type))}
          </div>
        )}
        {slash ? (
          <MenuRichItem
            icon={<BlockTypeIcon type={option.type} />}
            render={
              <button
                id={slash.id(index)}
                type="button"
                tabIndex={-1}
                role="option"
                aria-selected={index === slash.index}
                aria-description={detail}
                onMouseDown={event => event.preventDefault()}
                onMouseEnter={() => slash.highlight(index)}
                onClick={() => onChoose(option.type)}
              />
            }>
            <span title={detail}>{title}</span>
          </MenuRichItem>
        ) : (
          <DropdownMenuItem
            data-current={current === option.type}
            aria-current={current === option.type ? 'true' : undefined}
            aria-description={detail}
            onClick={() => onChoose(option.type)}>
            <BlockTypeIcon type={option.type} />
            <span title={detail}>{title}</span>
            {current === option.type && <CheckmarkRegular className="ms-auto" aria-hidden />}
          </DropdownMenuItem>
        )}
      </Fragment>
    )
  })
}
