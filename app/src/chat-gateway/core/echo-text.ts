/**
 * Text emitted by the temporary Chat Gateway V1 echo runtime.
 *
 * Keeping this helper shared matters for edit mirroring: an edited inbound
 * message must rewrite the previously posted BullX reply with exactly the same
 * placeholder format that a fresh inbound message would have produced.
 */
export function echoPlaceholderText(agentUid: string, inboundText: string): string {
  const text = inboundText.trim()
  const suffix = text ? `\n\n${text}` : ''
  return `[BullX Agent Chat Gateway V1 echo placeholder:${agentUid}]${suffix}`
}
