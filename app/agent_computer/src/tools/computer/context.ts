import type { ContainerComputer } from './computer'
import type { Drive } from '../../drive/drive'

export interface ComputerToolContext {
  agentHome: string
  /** Session or Job workspace for the active turn. */
  workspaceRoot: string
  /** The Agent's drive in the control plane. */
  drive: Drive
  computer: ContainerComputer
}
