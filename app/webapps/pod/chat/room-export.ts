import type { ConversationDetail } from '../api'
import { conversationDetail } from '../api/generated/sdk.gen'
import { downloadMarkdown } from './export-markdown'
import { toast } from '@ankole/uikit'
import { t } from 'i18next'
import { contentError } from '../content-errors'
import { requestErrorMessage } from '../../common/request-errors'

export async function exportConversation(detail: ConversationDetail) {
  try {
    const messages = new Map(detail.messages.map(message => [message.id, message]))
    let before = detail.olderMessagesBeforeSeq
    while (before != null) {
      const older = await conversationDetail({ path: { id: detail.conversation.id }, query: { beforeSeq: before } })
      for (const message of older.messages) messages.set(message.id, message)
      before = older.olderMessagesBeforeSeq
    }
    downloadMarkdown({ ...detail, messages: [...messages.values()].sort((a, b) => a.seq - b.seq) })
  } catch (error) {
    toast.error(`${t('pod.chat_room.export_failed')}: ${requestErrorMessage(contentError(error))}`)
  }
}
