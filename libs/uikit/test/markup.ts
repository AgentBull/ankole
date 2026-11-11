import type { ReactElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'

const entities: Record<string, string> = { '&amp;': '&', '&gt;': '>', '&lt;': '<', '&quot;': '"', '&#x27;': "'" }

function decode(text: string) {
  return text.replace(/&(amp|gt|lt|quot|#x27);/g, entity => entities[entity]!)
}

/** The opening tag of the one element in static markup whose attributes include `attribute`. */
export function tagWith(html: string, attribute: string): string {
  const found = [...html.matchAll(/<[a-z][^>]*>/g)].map(match => match[0]).filter(tag => tag.includes(attribute))
  if (found.length !== 1) throw new Error(`expected one element with ${attribute}, found ${found.length}`)
  return found[0]!
}

/** The class names of an opening tag, with the HTML escapes that React writes into attributes undone. */
export function classesOf(tag: string): string[] {
  const value = /\bclass="([^"]*)"/.exec(tag)?.[1] ?? ''
  return decode(value).split(/\s+/).filter(Boolean)
}

/** The `d` attribute that an icon draws, to find that icon inside other markup. */
export function pathOf(icon: ReactElement): string {
  const path = /\sd="[^"]+"/.exec(renderToStaticMarkup(icon))?.[0]
  if (!path) throw new Error('the icon draws no path')
  return path.trim()
}

/** The value of one attribute of an opening tag, or `undefined` when the tag lacks it. */
export function attributeOf(tag: string, name: string): string | undefined {
  const value = new RegExp(`\\s${name}="([^"]*)"`).exec(tag)?.[1]
  return value === undefined ? undefined : decode(value)
}
