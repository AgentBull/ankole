import type { ContainerComputer } from './computer'

export interface ComputerToolContext {
  agentHome: string
  /** Session or Job workspace for the active turn. */
  workspaceRoot: string
  computer: ContainerComputer
}
