import type { Meta, StoryObj } from '@storybook/react'

import { Kbd, KbdGroup } from '../components/kbd'

const meta = {
  title: 'Components/Kbd',
  component: Kbd,
  args: { children: 'K' }
} satisfies Meta<typeof Kbd>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const SingleKeys: Story = {
  render: () => (
    <div className="flex gap-2">
      <Kbd>⌘</Kbd>
      <Kbd>⇧</Kbd>
      <Kbd>↵</Kbd>
      <Kbd>Esc</Kbd>
      <Kbd>Tab</Kbd>
    </div>
  )
}

export const Combo: Story = {
  render: () => (
    <KbdGroup>
      <Kbd>⌘</Kbd>
      <Kbd>K</Kbd>
    </KbdGroup>
  )
}

export const InText: Story = {
  render: () => (
    <p className="text-sm text-muted-foreground">
      Press{' '}
      <KbdGroup>
        <Kbd>⌘</Kbd>
        <Kbd>K</Kbd>
      </KbdGroup>{' '}
      to open command palette.
    </p>
  )
}
