import { GardState } from '../state'
import { LineBreak } from '../types'

import { strong, emphasis, code, underline, strikethrough, superscript, subscript } from './mark'
import { blockDoc, inlineDoc, paragraph, heading, alignment, direction, blockquote, horizontalRule } from './block'
import { codeBlock } from './code'
import { bulletList, orderedList } from './list'
import { image, figure, imageResizing } from './image'
import { color, backgroundColor } from './color'
import { link } from './link'

/** Returns an extension that enables {@link LineBreak line breaks}. */
export function lineBreak(): GardState.Extension {
  return GardState.schemaElement.of(LineBreak)
}

/**
 * Enable the {@link strong}, {@link emphasis}, and {@link link}
 * marks.
 */
export function basicMarks(): GardState.Extension {
  return [strong(), emphasis(), link()]
}

/**
 * Enable {@link strong}, {@link emphasis}, {@link code}, {@link
 * link}, {@link underline}, {@link strikethrough}, {@link
 * superscript}, {@link color}, and {@link backgroundColor}.
 */
export function inlineMarks(): GardState.Extension {
  return [basicMarks(), code(), underline(), strikethrough(), superscript(), subscript(), color(), backgroundColor()]
}

/**
 * Add the elements of a simple rich text schema: {@link blockDoc},
 * {@link basicMarks}, {@link paragraph}, {@link heading}, and {@link
 * lineBreak}.
 */
export function basicSchema(): GardState.Extension {
  return [blockDoc(), basicMarks(), paragraph(), heading(), lineBreak()]
}

/**
 * Add the extensions for a simple schema where the document is a
 * single textblock: {@link inlineDoc}, {@link basicMarks}, {@link
 * image}, and {@link lineBreak}.
 */
export function inlineSchema(): GardState.Extension {
  return [inlineDoc(), basicMarks(), image(), lineBreak()]
}

/**
 * Returns an extension with all the schema elements included in this
 * module, in a {@link blockDoc block document}. Note that new
 * elements may appear in this schema as new versions of the library
 * add new features.
 */
export function fullSchema(): GardState.Extension {
  return [
    blockDoc(),
    paragraph(),
    heading(),
    lineBreak(),
    codeBlock(),
    alignment(),
    direction(),
    blockquote(),
    horizontalRule(),
    bulletList(),
    orderedList(),
    inlineMarks(),
    image(),
    figure(),
    imageResizing()
  ]
}
