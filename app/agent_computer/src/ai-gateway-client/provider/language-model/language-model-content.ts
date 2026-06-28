import type { LanguageModelCustomContent } from './language-model-custom-content'
import type { LanguageModelFile } from './language-model-file'
import type { LanguageModelReasoning } from './language-model-reasoning'
import type { LanguageModelReasoningFile } from './language-model-reasoning-file'
import type { LanguageModelSource } from './language-model-source'
import type { LanguageModelText } from './language-model-text'
import type { LanguageModelToolApprovalRequest } from './language-model-tool-approval-request'
import type { LanguageModelToolCall } from './language-model-tool-call'
import type { LanguageModelToolResult } from './language-model-tool-result'

export type LanguageModelContent =
  | LanguageModelText
  | LanguageModelReasoning
  | LanguageModelCustomContent
  | LanguageModelReasoningFile
  | LanguageModelFile
  | LanguageModelToolApprovalRequest
  | LanguageModelSource
  | LanguageModelToolCall
  | LanguageModelToolResult
