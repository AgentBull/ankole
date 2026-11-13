import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { ConversationGlyph, type RoomRow } from './conversation-row'

const agent = { uid: 'writer', displayName: 'Writer', avatarURL: null }
const room = (conversationKind: RoomRow['conversationKind'], agents = [agent]) =>
  ({ id: 'room-1', title: 'Growth team', conversationKind, agents }) as unknown as RoomRow

/** The opening tag of the kit avatar in the markup, or `undefined` without one. */
const avatarTag = (html: string) => /<span[^>]*data-slot="avatar"[^>]*>/.exec(html)?.[0]

describe('conversation marks', () => {
  test('give a group and a colleague DM the same rounded-square avatar at every size', () => {
    for (const size of ['sm', 'md', 'lg'] as const) {
      const group = avatarTag(renderToStaticMarkup(<ConversationGlyph room={room('group')} size={size} />))
      const dm = avatarTag(renderToStaticMarkup(<ConversationGlyph room={room('colleague_dm')} size={size} />))
      expect(group).toBeDefined()
      expect(group).toContain('data-shape="square"')
      // Apart from the name in its tooltip, the group's avatar is the DM's avatar.
      expect(group!.replace(/title="[^"]*"/, '')).toBe(dm!.replace(/title="[^"]*"/, ''))
    }
  })

  test('draw the 32px avatar of a two-line row without the one-line mark slot', () => {
    const html = renderToStaticMarkup(<ConversationGlyph room={room('group')} size="lg" />)
    expect(avatarTag(html)).toContain('data-size="default"')
    expect(html).not.toContain('pod-conversation-glyph')
  })

  test('mark an assistant task with the plain conversation glyph instead of an avatar', () => {
    const html = renderToStaticMarkup(<ConversationGlyph room={room('assistant_task', [])} />)
    expect(avatarTag(html)).toBeUndefined()
    expect(html).toContain('pod-conversation-glyph')
  })
})
