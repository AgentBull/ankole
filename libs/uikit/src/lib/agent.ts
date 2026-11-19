// Apps reach ui-sdk's agent bridge through the kit, so the bridge shares the one core copy that the kit's components
// register with.
export { createAgent, registerTools, type AgentAction } from '@ui-sdk/react/agent'
