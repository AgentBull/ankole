import { PhraseSet } from './phraseset'

/** The phrase set for the core package and basic menu items. */
export const phrases = PhraseSet.define({
  dialog_close: 'close',

  // Menu labels
  overflow_more: 'More',
  block_style: 'Block style',
  toggle_strong: 'Toggle strong emphasis',
  toggle_em: 'Toggle emphasis',
  toggle_code: 'Toggle code font',
  toggle_underline: 'Toggle underline',
  toggle_strikethrough: 'Toggle strikethrough',
  toggle_super: 'Toggle superscript',
  toggle_sub: 'Toggle subscript',
  link_target: 'Link target',
  create_link: 'Create link',
  text_color: 'Text color',
  background_color: 'Background color',
  undo: 'Undo',
  redo: 'Redo',
  paragraph: 'Paragraph',
  code_block: 'Code block',
  heading_1: 'Heading 1',
  heading_2: 'Heading 2',
  heading_3: 'Heading 3',
  toggle_bullet_list: 'Toggle bullet list',
  toggle_ordered_list: 'Toggle ordered list',
  toggle_quote: 'Toggle blockquote',
  alignment: 'Alignment',
  align_start: 'Align text to block start',
  align_end: 'Align text to block end',
  align_center: 'Center text',
  text_dir: 'Text direction',
  text_dir_ltr: 'Left-to-right text',
  text_dir_rtl: 'Right-to-left text',
  text_dir_auto: 'Automatic text direction'
})

/** Phrases used by the {@link schema.image.button image dialog}. */
export const imagePhrases = PhraseSet.define({
  insert_image: 'Insert image',
  update_image: 'Update image',
  update: 'Update',
  insert: 'Insert',
  cancel: 'Cancel',
  inline: 'Inline',
  figure: 'Figure',
  figure_center: 'Centered figure',
  figure_end: 'Figure aligned to end',
  captioned: 'Captioned',
  image_style: 'Image style',
  uploading: 'Uploading...',
  upload_failed: 'Image upload failed',
  width: 'Width in pixels',
  upload_image: 'Upload an image',
  image_source: 'Image source',
  alt_text: 'Alternative text',
  describe_image: 'Describe the image',
  auto: 'automatic'
})

/**
 * Phrases (mostly color names) used by the {@link schema.ColorPicker
 * color picker}.
 */
export const colorNames = PhraseSet.define({
  none: 'none',
  black: 'black',
  white: 'white',
  grey: 'grey',
  red_berry: 'red berry',
  red: 'red',
  orange: 'orange',
  yellow: 'yellow',
  green: 'green',
  cyan: 'cyan',
  cornflower: 'cornflower',
  blue: 'blue',
  purple: 'purple',
  magenta: 'magenta',
  dark: 'dark',
  darker: 'darker',
  darkest: 'very dark',
  light: 'light',
  lighter: 'lighter',
  lightest: 'very light'
})

/** Phrases used by [wordgard/table](#table). */
export const tablePhrases = PhraseSet.define({
  dimensions_title: 'Table dimensions $1 by $2. Use arrow keys to change.',
  dimensions_live: '$1 by $2',
  insert_table: 'Insert a table',
  modify_table: 'Modify table',
  toggle_header: 'Toggle header cells',
  add_row_above: 'Add row above',
  add_row_below: 'Add row below',
  delete_row: 'Delete row',
  add_col_before: 'Add column before',
  add_col_after: 'Add column before',
  delete_col: 'Delete column',
  merge_cells: 'Merge cells',
  split_cell: 'Split cell'
})
