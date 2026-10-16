import { GardState } from '../state'

const phraseOverride = GardState.Facet.define<
  { set: PhraseSet<any>; phrases: Record<string, string> },
  Map<PhraseSet<any>, Record<string, string>>
>({
  combine(records) {
    const map = new Map<PhraseSet<any>, Record<string, string>>()
    for (let i = records.length - 1; i >= 0; i--) {
      const { set, phrases } = records[i]!
      const known = map.get(set)
      map.set(set, known ? { ...known, ...phrases } : phrases)
    }
    return map
  }
})

/**
 * A phrase set defines a number of text phrases to display in the
 * user interface, and makes translation of those phrases possible.
 * It associates each phrase with a tag. The type parameter to this
 * class is the set of tag names it defines.
 */
export class PhraseSet<Tags extends string> {
  private constructor(readonly phrases: { [tag in Tags]: string }) {}

  private refs: Map<Tags, PhraseSet.Ref> = new Map()

  /**
   * Look up a translation for phrase with the given tag.
   *
   * If additional arguments are passed, they will be inserted in
   * place of markers like `$1` (for the first value) and `$2`, etc.
   * A single `$` is equivalent to `$1`, and `$$` will produce a
   * literal dollar sign.
   */
  get<Tag extends Tags>(state: GardState, tag: Tag, ...insert: any[]) {
    const override = state.facet(phraseOverride).get(this)
    let phrase = (override && override[tag]) ?? this.phrases[tag]
    if (insert.length) {
      phrase = phrase.replace(/\$(\$|\d*)/g, (m, i) => {
        if (i == '$') return '$'
        const n = +(i || 1)
        return !n || n > insert.length ? m : insert[n - 1]
      })
    }
    return phrase
  }

  /**
   * Create a reference to a phrase. Returns a function that can be
   * called with an editor state to get the phrase text.
   */
  ref<Tag extends Tags>(tag: Tag): PhraseSet.Ref {
    let found = this.refs.get(tag)
    if (!found) this.refs.set(tag, (found = (state, ...insert) => this.get(state, tag, ...insert)))
    return found
  }

  /**
   * Create a translation of this set. Adding the resulting extension
   * to an editor configuration will cause access to the phrases in
   * the set to return the translated text.
   */
  translate(phrases: { [tag in Tags]: string }): GardState.Extension {
    return phraseOverride.of({ set: this, phrases })
  }

  /**
   * Create a partial translation of this set. The only difference
   * with {@link PhraseSet.translate} is that this method won't cause
   * a type error when you omit some tags.
   */
  translatePartial(phrases: { [tag in Tags]?: string }): GardState.Extension {
    return phraseOverride.of({ set: this, phrases: phrases as Record<string, string> })
  }

  /**
   * Define a new phrase set. Takes an object as argument that
   * defines the default (usually English) text for all the tags in
   * the set.
   */
  static define<Tags extends string>(phrases: { [tag in Tags]: string }) {
    return new PhraseSet<Tags>(phrases)
  }

  /**
   * Check whether the phrase set configuration changed between the
   * two given states. Can be useful to check whether some part of
   * the interface needs to be redrawn.
   */
  static didChange(a: GardState, b: GardState) {
    return a.facet(phraseOverride) != b.facet(phraseOverride)
  }
}

export namespace PhraseSet {
  /**
   * A reference to a specific phrase. Call it with a state and,
   * optionally, the inserted values you'd pass to {@link
   * PhraseSet.get `PhraseSet.get`} to get a phrase.
   */
  export type Ref = (state: GardState, ...insert: any[]) => string

  /** Get the set of tags defined by a given phrase set, as a type. */
  export type Tag<Set extends PhraseSet<any>> = Set extends PhraseSet<infer T> ? T : never
}
