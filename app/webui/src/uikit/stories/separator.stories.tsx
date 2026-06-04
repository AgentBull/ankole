import type { Meta, StoryObj } from '@storybook/react'

import { Separator } from '@/uikit/components/separator'

const meta = {
  title: 'Components/Separator',
  component: Separator,
  argTypes: {
    orientation: {
      control: 'radio',
      options: ['horizontal', 'vertical']
    }
  }
} satisfies Meta<typeof Separator>

export default meta

type Story = StoryObj<typeof meta>

export const Horizontal: Story = {
  render: () => (
    <div className="flex w-72 flex-col gap-3">
      <span className="text-sm">Above</span>
      <Separator />
      <span className="text-sm">Below</span>
    </div>
  )
}

export const Vertical: Story = {
  render: () => (
    <div className="flex h-12 items-center gap-3 text-sm">
      <span>Left</span>
      <Separator orientation="vertical" />
      <span>Middle</span>
      <Separator orientation="vertical" />
      <span>Right</span>
    </div>
  )
}
