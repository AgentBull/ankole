import type { Meta, StoryObj } from '@storybook/react'

import { Button } from '@/uikit/components/button'
import { Kbd, KbdGroup } from '@/uikit/components/kbd'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/uikit/components/tooltip'

const meta = {
  title: 'Components/Tooltip',
  component: Tooltip
} satisfies Meta<typeof Tooltip>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <Tooltip>
      <TooltipTrigger render={<Button variant="outline">Hover me</Button>} />
      <TooltipContent>This is a helpful tip.</TooltipContent>
    </Tooltip>
  )
}

export const Sides: Story = {
  render: () => (
    <div className="grid grid-cols-2 gap-3">
      {(['top', 'right', 'bottom', 'left'] as const).map(side => (
        <Tooltip key={side}>
          <TooltipTrigger render={<Button variant="outline" className="capitalize" />}>{side}</TooltipTrigger>
          <TooltipContent side={side}>{side} tooltip</TooltipContent>
        </Tooltip>
      ))}
    </div>
  )
}

export const WithKeyboardHint: Story = {
  render: () => (
    <Tooltip>
      <TooltipTrigger render={<Button variant="outline">Save</Button>} />
      <TooltipContent>
        Save changes
        <KbdGroup>
          <Kbd>⌘</Kbd>
          <Kbd>S</Kbd>
        </KbdGroup>
      </TooltipContent>
    </Tooltip>
  )
}
