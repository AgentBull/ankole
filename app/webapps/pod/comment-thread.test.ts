import { describe, expect, it } from 'bun:test'
import { collectMentionedAgentUIDs } from './comment-thread'

describe('collectMentionedAgentUIDs', () => {
  const agents = [
    { uid: 'bo', displayName: 'Bo' },
    { uid: 'bob', displayName: 'Bob' },
    { uid: 'reviewer-a', displayName: 'Reviewer' },
    { uid: 'reviewer-b', displayName: 'Reviewer' }
  ]

  it('enforces token boundaries so @bo does not match @bob or email addresses', () => {
    expect(collectMentionedAgentUIDs('Please check @bob on row 2', agents)).toEqual(['bob'])
    expect(collectMentionedAgentUIDs('Email user@bo.com about this', agents)).toEqual([])
    expect(collectMentionedAgentUIDs('Hey @bo, take a look!', agents)).toEqual(['bo'])
  })

  it('disambiguates agents sharing a displayName using selectedUIDs from autocomplete', () => {
    expect(collectMentionedAgentUIDs('@Reviewer check section 3', agents, new Set(['reviewer-b']))).toEqual([
      'reviewer-b'
    ])
    expect(collectMentionedAgentUIDs('@Reviewer check section 3', agents)).toEqual(['reviewer-a', 'reviewer-b'])
  })

  it('extracts structured <mention> and @[Name](principal:uid) tokens', () => {
    expect(
      collectMentionedAgentUIDs('Ping <mention uid="agent-x">@X</mention> and @[Helper](principal:agent-y)', agents)
    ).toEqual(['agent-x', 'agent-y'])
  })
})
