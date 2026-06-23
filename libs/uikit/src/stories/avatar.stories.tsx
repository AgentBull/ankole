import { RiCheckLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import { Avatar, AvatarBadge, AvatarFallback, AvatarGroup, AvatarGroupCount, AvatarImage } from '../components/avatar'

const SAMPLE_IMAGE = 'https://api.dicebear.com/9.x/glass/svg?seed=storybook'

const meta = {
  title: 'Components/Avatar',
  component: Avatar,
  argTypes: {
    size: {
      control: 'radio',
      options: ['sm', 'default', 'lg']
    }
  }
} satisfies Meta<typeof Avatar>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <Avatar {...args}>
      <AvatarImage src={SAMPLE_IMAGE} alt="User" />
      <AvatarFallback>BX</AvatarFallback>
    </Avatar>
  )
}

export const Fallback: Story = {
  render: args => (
    <Avatar {...args}>
      <AvatarFallback>JD</AvatarFallback>
    </Avatar>
  )
}

export const Sizes: Story = {
  render: () => (
    <div className="flex items-end gap-4">
      <Avatar size="sm">
        <AvatarFallback>SM</AvatarFallback>
      </Avatar>
      <Avatar size="default">
        <AvatarFallback>MD</AvatarFallback>
      </Avatar>
      <Avatar size="lg">
        <AvatarFallback>LG</AvatarFallback>
      </Avatar>
    </div>
  )
}

export const WithBadge: Story = {
  render: () => (
    <Avatar>
      <AvatarFallback>BX</AvatarFallback>
      <AvatarBadge>
        <RiCheckLine />
      </AvatarBadge>
    </Avatar>
  )
}

export const Group: Story = {
  render: () => (
    <AvatarGroup>
      <Avatar>
        <AvatarFallback>A</AvatarFallback>
      </Avatar>
      <Avatar>
        <AvatarFallback>B</AvatarFallback>
      </Avatar>
      <Avatar>
        <AvatarFallback>C</AvatarFallback>
      </Avatar>
      <AvatarGroupCount>+3</AvatarGroupCount>
    </AvatarGroup>
  )
}
