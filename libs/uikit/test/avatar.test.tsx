import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Avatar, AvatarDot, AvatarFallback } from '../src/components/avatar'
import { attributeOf, classesOf, tagWith } from './markup'

test('marks a person with a 4px dot centred 4px below the avatar in the colour that the caller gives', () => {
  const html = renderToStaticMarkup(
    <Avatar size="sm">
      <AvatarFallback>AR</AvatarFallback>
      <AvatarDot style={{ color: 'rgb(255 84 104)' }} />
    </Avatar>
  )

  const dot = tagWith(html, 'data-slot="avatar-dot"')
  expect(attributeOf(dot, 'aria-hidden')).toBe('true')
  expect(classesOf(dot)).toEqual(
    expect.arrayContaining([
      'absolute',
      '-bottom-2',
      'left-1/2',
      'size-1',
      '-translate-x-1/2',
      'rounded-full',
      'bg-current'
    ])
  )
  expect(attributeOf(dot, 'style')).toBe('color:rgb(255 84 104)')
})

test('keeps one shape: the picture, the initials fill, and the hairline edge take the avatar radius', () => {
  const html = renderToStaticMarkup(
    <Avatar className="rounded-[7px]">
      <AvatarFallback>AR</AvatarFallback>
    </Avatar>
  )
  const avatar = classesOf(tagWith(html, 'data-slot="avatar"'))
  expect(avatar).toContain('rounded-[7px]')
  expect(avatar).not.toContain('rounded-full')
  expect(avatar).toEqual(expect.arrayContaining(['after:border', 'after:rounded-[inherit]']))
  expect(avatar).not.toContain('after:rounded-full')
  expect(classesOf(tagWith(html, 'data-slot="avatar-fallback"'))).toContain('rounded-[inherit]')
  // Without a radius of its own the avatar is round.
  const round = classesOf(tagWith(renderToStaticMarkup(<Avatar />), 'data-slot="avatar"'))
  expect(round).toContain('rounded-full')
})

test('draws a 20px mark whose initials take the smallest type step', () => {
  const html = renderToStaticMarkup(
    <Avatar size="xs">
      <AvatarFallback>HP</AvatarFallback>
    </Avatar>
  )
  const avatar = tagWith(html, 'data-slot="avatar"')
  expect(attributeOf(avatar, 'data-size')).toBe('xs')
  expect(classesOf(avatar)).toContain('data-[size=xs]:size-5')
  const initials = classesOf(tagWith(html, 'data-slot="avatar-fallback"'))
  expect(initials).toContain('group-data-[size=xs]/avatar:text-25')
  expect(initials.some(name => /^text-\[\d+px\]$/.test(name))).toBe(false)
})
