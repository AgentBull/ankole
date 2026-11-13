import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { ConversationGlyph, conversationPreview, type RoomRow } from './conversation-row'

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

describe('conversation previews', () => {
  test('drop Markdown markers and keep the words', () => {
    expect(
      conversationPreview('是，你这个反问站得住。**对接口层来说**，[文档](https://example.com) 已经 ~~过时~~ 更新')
    ).toBe('是，你这个反问站得住。对接口层来说，文档 已经 过时 更新')
    expect(conversationPreview('## 结论\n> 引用一句\n- 第一点\n1. 第二点\n![图](a.png) `ankole-files`')).toBe(
      '结论 引用一句 第一点 第二点 图 ankole-files'
    )
  })

  test('keep the code of a message that is only a code block', () => {
    expect(conversationPreview('```python\nfrom dividend_radar import __init__\nprint(rank * 2)\n```')).toBe(
      'from dividend_radar import __init__ print(rank * 2)'
    )
    // The control plane cuts the source at 180 characters, which can leave a fence open.
    expect(conversationPreview('```ts\nconst top = 20')).toBe('const top = 20')
  })

  test('leave the text of code untouched while cleaning the prose around it', () => {
    expect(
      conversationPreview(
        '结果如下：\n```python\n# 求幂\nprint(2 ** 3)\nrows = data[0](limit)\n```\n- 用 `a ** b` 计算'
      )
    ).toBe('结果如下： # 求幂 print(2 ** 3) rows = data[0](limit) 用 a ** b 计算')
    expect(conversationPreview('> - [x] **完成**\n> > 嵌套引用')).toBe('完成 嵌套引用')
  })
})
