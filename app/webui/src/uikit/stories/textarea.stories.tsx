import type { Meta, StoryObj } from '@storybook/react'

import { Label } from '@/uikit/components/label'
import { Textarea } from '@/uikit/components/textarea'

const meta = {
  title: 'Components/Textarea',
  component: Textarea,
  args: { placeholder: 'Type your message…' },
  argTypes: {
    disabled: { control: 'boolean' }
  }
} satisfies Meta<typeof Textarea>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <div className="w-72">
      <Textarea {...args} />
    </div>
  )
}

export const WithLabel: Story = {
  render: () => (
    <div className="flex w-72 flex-col gap-2">
      <Label htmlFor="message">Message</Label>
      <Textarea id="message" placeholder="What's on your mind?" />
    </div>
  )
}

export const Disabled: Story = {
  args: { disabled: true, value: 'Read only content' },
  render: args => (
    <div className="w-72">
      <Textarea {...args} />
    </div>
  )
}

export const Invalid: Story = {
  render: () => (
    <div className="w-72">
      <Textarea aria-invalid placeholder="Required" />
    </div>
  )
}
