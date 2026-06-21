import { z } from 'zod'
import type { AgentTool, AgentToolResult } from '../core'
import { buildTool } from './build-tool'
import type { ClarifyRunBinding } from './clarify-tool'
import { formatChatHistorySearchResult, searchChatHistory, type ChatHistorySearchHit } from '@/chat-recall/service'

const ChatHistorySearchParams = z.object({
  query: z.string().min(1).describe('Natural language or keyword query to search prior chat history.'),
  limit: z.number().int().min(1).max(20).describe('Maximum number of recalled anchors to return.').optional()
})

/**
 * Structured echo of the recall query. `available` is false when the recall
 * subsystem could not run at all; `degradedReasons` reports a partial answer
 * (e.g. one source unreachable). Surfaced for logs/UI, not shown to the model.
 */
export interface ChatHistorySearchDetails {
  available: boolean
  degradedReasons?: string[]
  results: ChatHistorySearchHit[]
  unavailableReasons?: string[]
}

/**
 * Builds the `chat_history_search` tool: lets the agent recall what was said in
 * earlier external chats (DM or group) that this user and agent can both see.
 *
 * The long description is deliberately prescriptive — it steers routing: try
 * chat recall first for "what did we say / agree / decide" questions, and when
 * repeated searches turn up nothing, report that rather than escalating to web
 * or workspace tools. That keeps the agent from leaking a private question to
 * the open web. The `binding` scopes the search to the current
 * requester/room/conversation so recall respects who is allowed to see what.
 */
export function createChatHistorySearchTool(
  binding: ClarifyRunBinding
): AgentTool<typeof ChatHistorySearchParams, ChatHistorySearchDetails> {
  return buildTool({
    name: 'chat_history_search',
    label: 'Chat History Search',
    description:
      'Search prior external chat messages visible to the current user and agent. Use this first for questions about what was previously said, remembered, agreed, mentioned, or discussed in DM or group chat. If repeated focused searches find no relevant chat evidence, say the prior chat history does not contain the answer instead of escalating to web or workspace tools unless the user explicitly asks to search the web, files, or runtime.',
    schema: ChatHistorySearchParams,
    executionMode: 'parallel',
    isReadOnly: true,
    isDestructive: false,
    async execute(_toolCallId, params): Promise<AgentToolResult<ChatHistorySearchDetails>> {
      // The current conversation is excluded so recall surfaces *prior* context,
      // not the live thread the agent is already reading.
      const result = await searchChatHistory({
        agentUid: binding.agentUid,
        currentRoomId: binding.providerRoomId,
        excludeConversationId: binding.conversationId,
        limit: params.limit,
        query: params.query,
        requesterExternalId: binding.requesterExternalId,
        requesterPrincipalUid: binding.requesterPrincipalUid
      })
      return {
        content: [{ type: 'text', text: formatChatHistorySearchResult(result) }],
        details: {
          available: result.available,
          degradedReasons: result.degradedReasons,
          unavailableReasons: result.unavailableReasons,
          results: result.results
        }
      }
    }
  })
}
