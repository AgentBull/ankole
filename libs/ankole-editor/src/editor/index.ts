export { editorPhrases, type EditorLabels } from './phrases'
export { PageSession } from './page-session'
export {
  commentSelection,
  trackCommentSelection,
  commentRanges,
  revealComment,
  type CommentSelection,
  type CommentRange
} from './comments'
export { insertEmbed } from '../blocks/embed'
export type { EditorHost, EmbedAttributes, MentionItem, MentionQueryResult, MountMentionOptions } from './host-context'
export { commitMention, insertMention, mentionField, type MentionCategory, type MentionSession } from './mention'
export type { MentionTarget } from './schema'
export { PageCollaboration, type PageChanges } from './page-collaboration'
export { toggleFormat, undo, insertImage } from './commands'
export type { Wordgard as Editor } from '../core/editor'
export { GardSelection as EditorSelection } from '../core/state'

export { insertResource, type ResourceAttributes, type ResourceKind } from '../blocks/resources'
export { remoteSelections, type RemoteSelection } from './remote-selections'
