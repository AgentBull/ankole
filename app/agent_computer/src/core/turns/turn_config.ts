import { ms } from '@pleisto/active-support'

// Code default for the agent inactivity watchdog. Runtime overrides come from
// AppConfigure-backed `ai_agent.inactivity_timeout_ms`, never worker env vars.
export const TEXT_TURN_DEFAULT_INACTIVITY_TIMEOUT_MS = ms('30m')
