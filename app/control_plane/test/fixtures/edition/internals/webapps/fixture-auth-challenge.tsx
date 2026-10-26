import type { AuthChallengeSlotProps } from '../../app/webapps/auth/slots'

export default function FixtureAuthChallenge({ attemptKey, onChallengeStateChange }: AuthChallengeSlotProps) {
  return (
    <button
      type="button"
      data-attempt={attemptKey}
      onClick={() =>
        onChallengeStateChange({
          ready: true,
          headers: { 'x-fixture-challenge': 'passed' }
        })
      }>
      Pass fixture challenge
    </button>
  )
}
