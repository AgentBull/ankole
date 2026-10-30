import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { EmojiPickerCell } from '../src/components/emoji-cell'
import { IconPicker, type IconPickerLabels } from '../src/components/icon-picker'

const labels: IconPickerLabels = {
  searchPlaceholder: 'Search',
  searchLabel: 'Search',
  searchClear: 'Clear',
  searchResultsNone: 'No results',
  searchResultsOne: '1 result',
  searchResultsMany: '%n results',
  categoryNavigation: 'Categories',
  loading: 'Loading',
  loadingError: 'Could not load',
  retryLoading: 'Try again',
  skinToneNeutral: 'Default',
  skinToneLight: 'Light',
  skinToneMediumLight: 'Medium light',
  skinToneMedium: 'Medium',
  skinToneMediumDark: 'Medium dark',
  skinToneDark: 'Dark',
  emojiTab: 'Emoji',
  pictureTab: 'Local picture',
  remove: 'Remove',
  picturesLoading: 'Loading pictures',
  picturesError: 'Could not load pictures',
  picturesRetry: 'Retry',
  picturesEmpty: 'No pictures',
  upload: 'Upload picture',
  uploadTitle: 'Upload picture',
  uploadDescription: 'Square pictures work best.',
  uploadDropzone: 'Drop a picture',
  uploadFormats: 'PNG up to 1 MB',
  uploadNameLabel: 'Choose a name',
  uploadNamePlaceholder: 'my_icon',
  uploadNameHint: 'Only lowercase letters, numbers, and underscores.',
  uploadNamePreview: name => `This picture will be available as ${name}`,
  uploadNameInvalid: 'Invalid name',
  uploadAdd: 'Add picture',
  uploadCancel: 'Cancel',
  uploading: 'Uploading',
  uploadTooLarge: 'Too large',
  uploadUnsupported: 'Unsupported',
  uploadFailed: 'Failed'
}

const pictures = {
  items: [
    { id: 'metadata/custom-emoji/aa/brain.png', name: 'brain', url: '/api/v2/pod/metadata/files/content?path=brain' }
  ],
  onSelect: () => {},
  canUpload: true,
  upload: { open: false, onOpenChange: () => {}, onSubmit: () => {} }
}

describe('IconPicker', () => {
  test('renders the emoji and local-picture tabs with the Remove action', () => {
    const html = renderToStaticMarkup(
      <IconPicker
        activeIcon={null}
        defaultTab="picture"
        emoji={{ onSelect: () => {} }}
        labels={labels}
        onRemove={() => {}}
        pictures={pictures}
      />
    )

    expect(html).toContain('data-slot="icon-picker"')
    expect(html).toContain('>Emoji<')
    expect(html).toContain('>Local picture<')
    expect(html).toContain('>Remove<')
    expect(html).toContain('aria-label="brain"')
    expect(html).toContain('aria-label="Upload picture"')
    expect(html).toContain('src="/api/v2/pod/metadata/files/content?path=brain"')
  })

  test('renders standard emoji cells with Fluent Emoji and leaves custom cells to the host', () => {
    const emoji = {
      isActive: false,
      unified: '1f600',
      names: ['grinning'],
      emoji: '😀',
      isCustom: false,
      hasVariations: false
    }

    const standard = renderToStaticMarkup(
      <EmojiPickerCell emoji={emoji} type="button">
        😀
      </EmojiPickerCell>
    )
    expect(standard).toContain('ankole-fluent-emoji')
    expect(standard).toContain('😀')

    const custom = renderToStaticMarkup(
      <EmojiPickerCell emoji={{ ...emoji, isCustom: true, emoji: 'custom-id' }} type="button">
        <img src="/custom.png" alt="" />
      </EmojiPickerCell>
    )
    expect(custom).not.toContain('ankole-fluent-emoji')
    expect(custom).toContain('src="/custom.png"')
  })

  test('marks the current picture and omits Remove when the host cannot remove it', () => {
    const html = renderToStaticMarkup(
      <IconPicker
        activeIcon="metadata/custom-emoji/aa/brain.png"
        defaultTab="picture"
        emoji={{ onSelect: () => {} }}
        labels={labels}
        pictures={pictures}
      />
    )

    expect(html).toContain('aria-pressed="true"')
    expect(html).not.toContain('>Remove<')
  })
})
