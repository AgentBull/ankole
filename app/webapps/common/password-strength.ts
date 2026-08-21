export type PasswordStrengthLevel = 'weak' | 'fair' | 'good' | 'strong'

/** Maps a zxcvbn score (0-4) onto the four label levels the meter shows. */
export function strengthLevel(score: number): PasswordStrengthLevel {
  if (score <= 1) return 'weak'
  if (score === 2) return 'fair'
  if (score === 3) return 'good'
  return 'strong'
}

type PasswordScorer = (password: string) => number

let scorerPromise: Promise<PasswordScorer> | undefined

/**
 * Loads the zxcvbn scorer on first use. The dictionaries weigh hundreds of
 * kilobytes, so the bundler splits them into an async chunk and the first
 * render never waits for them. Configuration happens once per page.
 */
export function loadPasswordScorer(): Promise<PasswordScorer> {
  scorerPromise ??= Promise.all([import('@zxcvbn-ts/core'), import('@zxcvbn-ts/language-common')]).then(
    ([core, common]) => {
      const factory = new core.ZxcvbnFactory({
        dictionary: common.dictionary,
        graphs: common.adjacencyGraphs
      })
      // zxcvbn cost grows with input length; 72 characters keeps scoring
      // instant and matches the meter's advisory-only purpose.
      return password => factory.check(password.slice(0, 72)).score
    }
  )

  return scorerPromise
}
