'use client'

import {
  RiBasketballLine,
  RiBearSmileLine,
  RiBusLine,
  RiCloseLine,
  RiCupLine,
  RiEmotionLine,
  RiFlagLine,
  RiMusic2Line,
  RiSearchLine,
  RiSparklingLine,
  RiTimeLine,
  RiTShirtLine
} from '@remixicon/react'
import {
  Categories,
  CategoryNav,
  Empty,
  List,
  LoadError,
  Loading,
  Panel,
  Root,
  SearchInput,
  SkinTone,
  useSearchActions,
  useSearchState,
  Viewport,
  type CategoryIcons,
  type EmojiDataLoader,
  type PickerComponents,
  type PickerLabels,
  type SkinToneButtonRenderProps
} from 'emoji-picker-react/primitives'
import { cn } from '../lib/utils'
import { Button } from './button'
import { EmojiPickerCell } from './emoji-cell'
import { InputGroup, InputGroupAddon, InputGroupButton } from './input-group'
import { Spinner } from './spinner'

/**
 * The picker ships one dataset per language. Loaders stay at module scope so
 * the picker only reloads when the locale actually changes.
 */
const emojiDataLoaders = {
  en: () => import('emoji-picker-react/data/emojis-en'),
  ja: () => import('emoji-picker-react/data/emojis-ja'),
  ko: () => import('emoji-picker-react/data/emojis-ko'),
  zh: () => import('emoji-picker-react/data/emojis-zh')
} satisfies Record<string, EmojiDataLoader>

const categoryIcons: CategoryIcons = {
  [Categories.SUGGESTED]: <RiTimeLine aria-hidden className="size-4" />,
  [Categories.SMILEYS_PEOPLE]: <RiEmotionLine aria-hidden className="size-4" />,
  [Categories.ANIMALS_NATURE]: <RiBearSmileLine aria-hidden className="size-4" />,
  [Categories.FOOD_DRINK]: <RiCupLine aria-hidden className="size-4" />,
  [Categories.TRAVEL_PLACES]: <RiBusLine aria-hidden className="size-4" />,
  [Categories.ACTIVITIES]: <RiBasketballLine aria-hidden className="size-4" />,
  [Categories.OBJECTS]: <RiTShirtLine aria-hidden className="size-4" />,
  [Categories.SYMBOLS]: <RiMusic2Line aria-hidden className="size-4" />,
  [Categories.FLAGS]: <RiFlagLine aria-hidden className="size-4" />,
  [Categories.CUSTOM]: <RiSparklingLine aria-hidden className="size-4" />
}

function SkinToneButton({ tone, children: _glyph, className, ...props }: SkinToneButtonRenderProps) {
  return (
    <button {...props} className={cn('ankole-emoji-picker-tone-btn', className)}>
      <span aria-hidden className="ankole-emoji-picker-tone-swatch" data-tone={tone.skinTone} />
    </button>
  )
}

const pickerComponents: PickerComponents = {
  Emoji: EmojiPickerCell,
  SkinToneButton
}

function EmojiPickerSearch({ clearLabel = 'Clear' }: { clearLabel?: string }) {
  const { search } = useSearchState()
  const { clear } = useSearchActions()

  return (
    <div data-epr-part="search" className="ankole-emoji-picker-search">
      <InputGroup variant="overlay" className="overflow-hidden pr-1 pl-2.5">
        <InputGroupAddon align="inline-start" className="py-0">
          <RiSearchLine aria-hidden className="size-4 text-fg-tertiary" />
        </InputGroupAddon>
        <SearchInput
          data-slot="input-group-control"
          className="h-full min-w-0 flex-1 bg-transparent pr-1 pl-2 text-sm leading-5 text-foreground outline-none placeholder:text-fg-placeholder"
        />
        <InputGroupAddon align="inline-end" className="gap-0.5 py-0">
          {search.length > 0 && (
            <InputGroupButton size="icon-xs" aria-label={clearLabel} data-epr-part="search-clear" onClick={clear}>
              <RiCloseLine aria-hidden />
            </InputGroupButton>
          )}
          <SkinTone className="ankole-emoji-picker-skin-tone" />
        </InputGroupAddon>
      </InputGroup>
    </div>
  )
}

/** Load only the selected language; unsupported locales use the English dataset. */
export function emojiDataForLocale(locale: string): EmojiDataLoader {
  const language = locale.toLowerCase().split('-')[0] ?? ''
  return emojiDataLoaders[language as keyof typeof emojiDataLoaders] ?? emojiDataLoaders.en
}

export type EmojiPickerLabels = PickerLabels

export type EmojiPickerProps = {
  /** Called with the selected emoji, including any skin-tone or joined sequence. */
  onEmojiSelect: (emoji: string) => void
  className?: string
  height?: number | string
  /** Localized search, result, and skin-tone labels; omitted strings stay English. */
  labels?: Partial<EmojiPickerLabels>
  /** BCP 47 tag. `ja`, `ko`, and `zh` also load that language's emoji names. */
  locale?: string
  width?: number | string
}

/**
 * Ankole's themed emoji picker. Place it in an overlay that owns positioning
 * and dismissal, such as `PopoverContent`; the picker fills the width it is
 * given and keeps its own search, category, skin-tone, and recent-emoji state.
 */
export function EmojiPicker({
  onEmojiSelect,
  className,
  height = 'min(380px, 60dvh)',
  labels,
  locale = 'en-US',
  width = '100%'
}: EmojiPickerProps) {
  return (
    <Root
      categoryIcons={categoryIcons}
      className={cn('ankole-emoji-picker', className)}
      components={pickerComponents}
      cssLayer="base"
      emojiData={emojiDataForLocale(locale)}
      labels={labels}
      lang={locale}
      onEmojiClick={emoji => onEmojiSelect(emoji.emoji)}
      suggestedEmojisMode="recent"
      style={{ width, height }}>
      <Panel>
        <EmojiPickerSearch clearLabel={labels?.searchClear} />
        <CategoryNav className="ankole-emoji-picker-categories" />
        <Viewport className="ankole-emoji-picker-viewport">
          <List />
          <Empty className="ankole-emoji-picker-status" />
          <Loading className="ankole-emoji-picker-status">
            <Spinner aria-hidden className="size-4 shrink-0 text-muted-foreground" />
            <span>{labels?.loading ?? 'Loading…'}</span>
          </Loading>
          <LoadError className="ankole-emoji-picker-error">
            {({ retry }) => (
              <>
                <p className="text-center text-sm leading-5 text-muted-foreground">
                  {labels?.loadingError ?? "Couldn't load emojis."}
                </p>
                <Button variant="outline" size="sm" onClick={retry}>
                  {labels?.retryLoading ?? 'Try again'}
                </Button>
              </>
            )}
          </LoadError>
        </Viewport>
      </Panel>
    </Root>
  )
}
