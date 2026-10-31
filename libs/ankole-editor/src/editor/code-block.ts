import type { Language, Token } from '@vortexlabs/kirari/core'
import { createRegistry } from '@vortexlabs/kirari/registry'
import { Elt, type Plot } from '../core/doc'
import { Decoration, Wordgard } from '../core/editor'
import type { Widget } from '../core/editor/decoration'
import { history } from '../core/history'
import { GardState, Transaction } from '../core/state'
import * as T from '../core/types'
import { markChange } from './attributes'
import { editorPhrases } from './phrases'
import * as S from './schema'
import { connectedWidget, widgetBlock } from './widget'

/** The languages Kirari can highlight, with the labels people expect to read in the menu. */
const languageLabels: Readonly<Record<string, string>> = {
  c: 'C',
  clojure: 'Clojure',
  cpp: 'C++',
  csharp: 'C#',
  css: 'CSS',
  dart: 'Dart',
  diff: 'Diff',
  dockerfile: 'Dockerfile',
  dotenv: 'Dotenv',
  elixir: 'Elixir',
  glsl: 'GLSL',
  go: 'Go',
  graphql: 'GraphQL',
  groovy: 'Groovy',
  hcl: 'HCL',
  html: 'HTML',
  ini: 'INI',
  java: 'Java',
  javascript: 'JavaScript',
  json: 'JSON',
  jsonc: 'JSONC',
  jsx: 'JSX',
  julia: 'Julia',
  kotlin: 'Kotlin',
  lua: 'Lua',
  makefile: 'Makefile',
  markdown: 'Markdown',
  nginx: 'Nginx',
  php: 'PHP',
  plaintext: 'Plain Text',
  powershell: 'PowerShell',
  protobuf: 'Protocol Buffers',
  python: 'Python',
  r: 'R',
  ruby: 'Ruby',
  rust: 'Rust',
  scala: 'Scala',
  shell: 'Shell',
  sql: 'SQL',
  svelte: 'Svelte',
  swift: 'Swift',
  toml: 'TOML',
  tsx: 'TSX',
  typescript: 'TypeScript',
  vue: 'Vue',
  xml: 'XML',
  yaml: 'YAML',
  zig: 'Zig'
}

// Labels that people type even though they do not name the language.
const languageAliases: Readonly<Record<string, string>> = {
  clojure: 'clj cljs cljc edn',
  cpp: 'c++ cc cxx hpp hh hxx',
  csharp: 'c# cs dotnet',
  diff: 'patch',
  dockerfile: 'docker',
  dotenv: 'env',
  elixir: 'ex exs',
  go: 'golang',
  graphql: 'gql',
  groovy: 'gradle',
  hcl: 'tf tfvars terraform',
  html: 'htm',
  ini: 'cfg',
  javascript: 'js mjs cjs node',
  julia: 'jl',
  kotlin: 'kt kts',
  makefile: 'make mk gnumakefile',
  markdown: 'md mdown',
  plaintext: 'text txt plain none',
  powershell: 'ps1 psm1 psd1 pwsh',
  protobuf: 'proto',
  python: 'py pyw pyi',
  r: 'rscript',
  ruby: 'rb rake gemspec gemfile',
  rust: 'rs',
  scala: 'sc',
  shell: 'sh bash zsh ksh bashrc zshrc',
  typescript: 'ts mts cts',
  xml: 'xsl xsd svg',
  yaml: 'yml'
}

export type CodeLanguageOption = {
  id: string
  label: string
  aliases: string
}

const allLanguages: readonly Language[] = Object.keys(languageLabels).map(name => ({ name, rules: [] }))
const registry = createRegistry(allLanguages)

/** Every language in the picker, ordered by label with Plain Text first. */
export const codeLanguages: readonly CodeLanguageOption[] = allLanguages
  .map(language => ({
    id: language.name,
    label: languageLabels[language.name] ?? language.name,
    aliases: languageAliases[language.name] ?? ''
  }))
  .sort((a, b) => (a.id === 'plaintext' ? -1 : b.id === 'plaintext' ? 1 : a.label.localeCompare(b.label, 'en')))

const languageByID = new Map(codeLanguages.map(option => [option.id, option]))

/** What a stored language value resolves to. Missing and unknown values are distinct. */
export type CodeLanguageState = {
  /** The value written on the block, or undefined when no language is set. */
  raw: string | undefined
  /** Kirari's canonical name (`plaintext` when no language is set), or null when unknown. */
  canonical: string | null
}

export function codeLanguageState(lang: string | undefined): CodeLanguageState {
  const raw = lang?.trim() ? lang.trim() : undefined
  if (!raw) return { raw: undefined, canonical: 'plaintext' }
  return { raw, canonical: registry.resolve(raw)?.name ?? null }
}

/** The label for a stored language value, including aliases such as `js`. */
export function codeLanguageLabel(lang: string | undefined, plainText = 'Plain Text'): string {
  const { raw, canonical } = codeLanguageState(lang)
  if (!canonical) return raw!
  return canonical === 'plaintext' ? plainText : (languageByID.get(canonical)?.label ?? raw ?? plainText)
}

/** Filter the picker by label, canonical name, or a common alias. */
export function filterCodeLanguages(query: string): readonly CodeLanguageOption[] {
  const text = query.trim().toLowerCase()
  if (!text) return codeLanguages
  // An exact name or alias comes first, then a word that starts with the query, so `ts` finds TypeScript.
  const rank = (option: CodeLanguageOption) => {
    const words = `${option.label} ${option.id} ${option.aliases}`.toLowerCase().split(/\s+/)
    if (words.includes(text)) return 0
    if (words.some(word => word.startsWith(text))) return 1
    return words.join(' ').includes(text) ? 2 : -1
  }
  return codeLanguages
    .map(option => ({ option, rank: rank(option) }))
    .filter(entry => entry.rank >= 0)
    .sort((a, b) => a.rank - b.rank)
    .map(entry => entry.option)
}

type Highlighter = {
  tokenize: typeof import('@vortexlabs/kirari/core').tokenize
  registry: ReturnType<typeof createRegistry>
}
let highlighter: Highlighter | undefined
let loading: Promise<void> | undefined

/** Load grammar code only when a document actually contains highlighted code. */
export function loadCodeHighlighter(): Promise<void> {
  return (loading ??= Promise.all([import('@vortexlabs/kirari/core'), import('@vortexlabs/kirari/languages')])
    .then(([core, languages]) => {
      highlighter = { tokenize: core.tokenize, registry: createRegistry(Object.values(languages)) }
    })
    .catch(error => {
      loading = undefined
      throw error
    }))
}

const refreshHighlight = Transaction.Effect.define<null>()
const loadHighlight = Wordgard.Plugin.define(editor => {
  let disposed = false
  let pending = false
  const load = () => {
    if (highlighter || pending) return
    let needed = false
    editor.state.doc.iterate(node => {
      if (node.type === T.CodeBlock.type && node.isPlot) {
        const language = codeLanguageState(node.mark(T.CodeBlockLanguage)).canonical
        if (language && language !== 'plaintext') needed = true
        return false
      }
    })
    if (!needed) return
    pending = true
    void loadCodeHighlighter()
      .then(() => {
        if (!disposed) editor.dispatch({ effects: refreshHighlight.of(null) })
      })
      .catch(() => {
        // The source stays editable if highlighting cannot load; a later edit can retry.
      })
      .finally(() => {
        pending = false
      })
  }
  load()
  return {
    update: load,
    remove: () => {
      disposed = true
    }
  }
})

const tokenCache = new WeakMap<Plot, { source: string; lang: string | undefined; tokens: readonly Token[] }>()

function tokensOf(node: Plot): readonly Token[] {
  if (!highlighter) return []
  const source = node.textContent()
  const lang = node.mark(T.CodeBlockLanguage)
  const cached = tokenCache.get(node)
  if (cached?.source === source && cached.lang === lang) return cached.tokens
  let tokens: readonly Token[] = []
  const language = highlighter.registry.resolve(lang ?? 'plaintext')
  if (source && language) {
    try {
      tokens = highlighter.tokenize(source, language)
    } catch {
      // An unhighlighted block stays editable.
    }
  }
  tokenCache.set(node, { source, lang, tokens })
  return tokens
}

/** Range decorations that paint Kirari's token classes over every code block. */
export function codeHighlight(state: GardState): Decoration.Range.Set {
  const ranges: [Decoration.Range, number, number][] = []
  state.doc.iterate((node, pos) => {
    if (node.type !== T.CodeBlock.type || !node.isPlot) return
    const start = pos + 1
    let merged: { type: string; from: number; to: number } | null = null
    const flush = () => {
      if (!merged) return
      const { type, from, to } = merged
      merged = null
      if (from >= to) return
      ranges.push([
        Decoration.Range.wrapper('span', {
          attributes: { class: `kirari-${type}` },
          spanning: false,
          rank: 90
        }),
        from,
        to
      ])
    }
    for (const token of tokensOf(node)) {
      if (token.type === 'text' || token.end <= token.start) continue
      const from = start + token.start
      const to = start + token.end
      if (merged && merged.type === token.type && merged.to === from) merged.to = to
      else {
        flush()
        merged = { type: token.type, from, to }
      }
    }
    flush()
    // Code text has no editable children worth visiting separately.
    return false
  })
  return ranges.length ? Decoration.Range.set(ranges) : Decoration.Range.none
}

/** Highlight ranges for the current document, recomputed only when the document changes. */
export const codeHighlightField = GardState.Field.define<Decoration.Range.Set>({
  create: state => codeHighlight(state),
  update: (value, tr) =>
    tr.docChanged || tr.effects.some(effect => effect.is(refreshHighlight)) ? codeHighlight(tr.state) : value,
  provide: field => Decoration.Range.source.of(state => state.field(field))
})

/** The code-language picker is open for this block position, or null. */
export const codeLanguageField = GardState.Field.define<number | null>({
  create: () => null,
  update(value, tr) {
    let pos = value !== null && tr.docChanged ? tr.changes.mapPos(value, -1) : value
    for (const effect of tr.effects) {
      if (effect.is(openCodeLanguage)) pos = effect.value
      else if (effect.is(closeCodeLanguage)) pos = null
    }
    return pos !== null && tr.state.doc.nodeAt(pos)?.type === T.CodeBlock.type ? pos : null
  }
})

/** Open the language picker for the code block at this position. */
export const openCodeLanguage = Transaction.Effect.define<number>()
/** Close the language picker. */
export const closeCodeLanguage = Transaction.Effect.define<null>()

/** Store a language on the code block at `pos`. Plain Text removes the language mark. */
export function chooseCodeLanguage(editor: Wordgard, pos: number, id: string) {
  if (editor.state.readOnly) return
  editor.dispatch({
    changes: markChange(editor.state.doc.nodeAt(pos), pos, T.CodeBlockLanguage, id === 'plaintext' ? null : id),
    effects: closeCodeLanguage.of(null),
    annotations: history.isolate.of(true),
    userEvent: 'code.setLanguage'
  })
}

type CodeToolbarValue = {
  wrap: boolean
  readOnly: boolean
  labels: {
    title: string
    language: string
    copy: string
    copied: string
    wrap: string
  }
}

function toolbarButton(text: string, title: string, action: string): HTMLButtonElement {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = `editor-code-${action}`
  button.dataset.codeAction = action
  button.textContent = text
  button.title = title
  button.setAttribute('aria-label', title)
  button.tabIndex = 0
  return button
}

function codeToolbar(value: CodeToolbarValue): HTMLDivElement {
  const bar = document.createElement('div')
  bar.className = 'editor-code-toolbar'
  bar.contentEditable = 'false'

  const title = document.createElement('span')
  title.className = 'editor-code-title'
  title.textContent = value.labels.title
  bar.append(title)

  const language = value.readOnly
    ? document.createElement('span')
    : toolbarButton(value.labels.language, value.labels.language, 'language')
  language.className = 'editor-code-language'
  if (value.readOnly) language.textContent = value.labels.language
  bar.append(language)

  if (!value.readOnly) {
    const wrap = toolbarButton(value.labels.wrap, value.labels.wrap, 'wrap')
    wrap.setAttribute('aria-pressed', String(value.wrap))
    bar.append(wrap)
  }

  bar.append(toolbarButton(value.labels.copy, value.labels.copy, 'copy'))
  return bar
}

const codeToolbarWidget = connectedWidget<CodeToolbarValue, HTMLDivElement>({
  render: value => codeToolbar(value),
  connect: (value, bar, editor) => {
    // The editor ignores widget events. The bar handles its own.
    const find = () => {
      const found = widgetBlock(editor, bar)
      return found?.node.isPlot && found.node.type === T.CodeBlock.type
        ? { pos: found.pos, node: found.node as Plot }
        : null
    }
    const mouseDown = (event: MouseEvent) => {
      if ((event.target as Element | null)?.closest('[data-code-action]')) event.preventDefault()
    }
    const click = (event: MouseEvent) => {
      const target = (event.target as Element | null)?.closest<HTMLElement>('[data-code-action]')
      if (!target) return
      event.preventDefault()
      const action = target.dataset.codeAction
      const found = find()
      if (!found) return
      if (action === 'copy') {
        const text = found.node.textContent()
        if (!navigator.clipboard) return
        void navigator.clipboard
          .writeText(text)
          .then(() => {
            target.textContent = value.labels.copied
            setTimeout(() => {
              if (target.isConnected) target.textContent = value.labels.copy
            }, 1500)
          })
          .catch(() => undefined)
      } else if (action === 'wrap' && !value.readOnly) {
        const wrapped = found.node.mark(S.CodeWrap) !== undefined
        editor.dispatch({
          changes: markChange(found.node, found.pos, S.CodeWrap, wrapped ? null : 'true'),
          annotations: history.isolate.of(true),
          userEvent: 'code.wrap'
        })
      } else if (action === 'language' && !value.readOnly) {
        const open = editor.state.field(codeLanguageField, false) === found.pos
        editor.dispatch({ effects: open ? closeCodeLanguage.of(null) : openCodeLanguage.of(found.pos) })
        // The picker takes focus when it opens; focusing the editor here would pull it back.
        if (open) editor.focus()
        return
      }
      editor.focus()
    }
    bar.addEventListener('mousedown', mouseDown)
    bar.addEventListener('click', click)
    return () => {
      bar.removeEventListener('mousedown', mouseDown)
      bar.removeEventListener('click', click)
    }
  },
  propagateEvent: false
})

/** The code block toolbar and its token highlight layers. */
export const codeBlockExtension: GardState.Extension = [
  codeLanguageField,
  codeHighlightField,
  loadHighlight,
  // The language and wrap attributes belong on the code element, not on the shell that holds the bar.
  Decoration.Mark.shape(T.CodeBlockLanguage, { attribute: 'data-language', value: 0, preferTarget: 'pre' }),
  Decoration.Mark.shape(S.CodeMeta, { attribute: 'data-meta', value: 0, preferTarget: 'pre' }),
  Decoration.Mark.shape(S.CodeWrap, { attribute: 'data-wrap', value: 0, preferTarget: 'pre' }),
  Decoration.Tag.shape.derived(T.CodeBlock.type, state => {
    const labels = {
      title: editorPhrases.get(state, 'code_title'),
      copy: editorPhrases.get(state, 'code_copy'),
      copied: editorPhrases.get(state, 'code_copied'),
      wrap: editorPhrases.get(state, 'code_wrap')
    }
    const readOnly = state.readOnly
    return tag => {
      const lang = tag.mark(T.CodeBlockLanguage)
      return Elt.mk<Widget | string>(
        'div',
        {
          class: 'editor-code-block',
          'data-wrap': tag.mark(S.CodeWrap) === undefined ? 'false' : 'true'
        },
        [
          codeToolbarWidget.of({
            wrap: tag.mark(S.CodeWrap) !== undefined,
            readOnly,
            labels: {
              ...labels,
              language: codeLanguageLabel(lang, editorPhrases.get(state, 'code_plain_text'))
            }
          }),
          Elt.mk<Widget | string>('pre', { class: 'editor-code-pre' }, [0])
        ]
      )
    }
  })
]
