import type { ContainerComputer } from './computer'
import type { Drive } from '../../drive/drive'

/** Shared state for the environment tools in one workspace. */
export interface ComputerToolContext {
  /** Agent-scoped filesystem home. */
  agentHome: string
  /** Session or Job workspace for the active turn. */
  workspaceRoot: string
  /** The Agent's drive in the control plane. */
  drive: Drive
  /** Environment tool executor for this workspace. */
  computer: ContainerComputer
}
