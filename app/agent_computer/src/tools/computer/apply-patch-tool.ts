import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../../core'
import type { ComputerToolContext } from './context'

const ApplyPatchInput = z
  .string()
  .min(1)
  .max(256 * 1024)

const ApplyPatchLarkGrammar = `start: begin_patch hunk+ end_patch
begin_patch: "*** Begin Patch" LF
end_patch: "*** End Patch" LF?

hunk: add_hunk | delete_hunk | update_hunk
add_hunk: "*** Add File: " filename LF add_line+
delete_hunk: "*** Delete File: " filename LF
update_hunk: "*** Update File: " filename LF change_move? change?

filename: /(.+)/
add_line: "+" /(.*)/ LF -> line

change_move: "*** Move to: " filename LF
change: (change_context | change_line)+ eof_line?
change_context: ("@@" | "@@ " /(.+)/) LF
change_line: ("+" | "-" | " ") /(.*)/ LF
eof_line: "*** End of File" LF

%import common.LF`

interface ApplyPatchDetails {
  exitCode: number
}

/**
 * Builds the same freeform apply_patch contract that Codex 0.146 exposes.
 */
export function createApplyPatchTool(
  context: ComputerToolContext
): AgentTool<typeof ApplyPatchInput, ApplyPatchDetails> {
  return {
    name: 'apply_patch',
    description:
      'The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.',
    schema: ApplyPatchInput,
    inputFormat: {
      type: 'grammar',
      syntax: 'lark',
      definition: ApplyPatchLarkGrammar
    },
    executionMode: 'sequential',
    isReadOnly: false,
    isDestructive: true,
    describeActivity: () => ({ key: 'signals_gateway.reply.activity.file_update' }),
    async execute(_toolCallID, patch, signal): Promise<AgentToolResult<ApplyPatchDetails>> {
      const computer = await context.getComputer(signal)
      const result = await computer.runCommand({
        cmd: 'apply_patch',
        cwd: context.workspaceRoot,
        stdin: patch,
        signal
      })
      const output = (await result.output('both', { signal })).trim()

      if (result.exitCode !== 0) {
        throw new Error(output || `apply_patch exited with code ${result.exitCode}`)
      }

      return {
        content: [{ type: 'text', text: output || 'Done!' }],
        details: { exitCode: result.exitCode }
      }
    }
  }
}
