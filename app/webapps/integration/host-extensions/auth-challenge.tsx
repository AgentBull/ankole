import type { AuthChallengeSlotProps } from '../../auth/slots'

export default function FixtureAuthChallenge({ attemptKey, onChallengeStateChange }: AuthChallengeSlotProps) {
  return (
    <button
      type="button"
      data-testid="fixture-challenge"
      data-attempt={attemptKey}
      onClick={() => onChallengeStateChange({ ready: true, headers: { 'x-fixture-challenge': attemptKey } })}>
      Pass fixture challenge
    </button>
  )
}
