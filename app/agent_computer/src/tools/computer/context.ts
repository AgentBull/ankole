import type { ContainerComputer } from './computer'
import type { DriveView } from '../../drive/mounts'

export interface ComputerToolContext {
  agentHome: string
  /** Session or Job workspace for the active turn. */
  workspaceRoot: string
  computer: ContainerComputer
  driveView?: DriveView
}
