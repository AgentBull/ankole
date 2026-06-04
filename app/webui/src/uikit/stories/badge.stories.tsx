import { RiCheckLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import { Badge } from '@/uikit/components/badge'

const meta = {
  title: 'Components/Badge',
  component: Badge,
  args: {
    children: 'Badge'
  },
  argTypes: {
    variant: {
      control: 'select',
      options: ['default', 'secondary', 'destructive', 'outline', 'ghost', 'link']
    }
  }
} satisfies Meta<typeof Badge>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const Variants: Story = {
  render: () => (
    <div className="flex flex-wrap items-center gap-3">
      <Badge variant="default">Default</Badge>
      <Badge variant="secondary">Secondary</Badge>
      <Badge variant="destructive">Destructive</Badge>
      <Badge variant="outline">Outline</Badge>
      <Badge variant="ghost">Ghost</Badge>
      <Badge variant="link">Link</Badge>
    </div>
  )
}

export const WithIcon: Story = {
  render: () => (
    <Badge>
      <RiCheckLine />
      Verified
    </Badge>
  )
}

export const AsLink: Story = {
  render: () => <Badge render={<a href="/" />}>Click me</Badge>
}
