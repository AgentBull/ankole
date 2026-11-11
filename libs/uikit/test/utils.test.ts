import { describe, expect, test } from 'bun:test'
import { cn } from '../src/lib/utils'

describe('cn', () => {
  test('reads an Ankole type step as a font size, so it replaces a size and keeps the colour', () => {
    expect(cn('text-foreground', 'text-75')).toBe('text-foreground text-75')
    expect(cn('text-sm leading-5', 'text-75')).toBe('text-75')
    expect(cn('text-75', 'text-[13px]')).toBe('text-[13px]')
    expect(cn('text-muted-foreground text-num-50', 'text-fg-secondary')).toBe('text-num-50 text-fg-secondary')
  })

  test('lets a theme radius, shell spacing, shadow, or blur replace the one before it', () => {
    expect(cn('rounded-control', 'rounded-surface')).toBe('rounded-surface')
    expect(cn('h-8', 'h-top-bar')).toBe('h-top-bar')
    expect(cn('w-60', 'w-sidebar')).toBe('w-sidebar')
    expect(cn('shadow-sm', 'shadow-control')).toBe('shadow-control')
    expect(cn('backdrop-blur-sm', 'backdrop-blur-composer')).toBe('backdrop-blur-composer')
  })
})
