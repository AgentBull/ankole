import type { Meta, StoryObj } from '@storybook/react'

import { Input } from '../components/input'
import { Label } from '../components/label'

const meta = {
  title: 'Components/Input',
  component: Input,
  args: { placeholder: 'Type here…' },
  argTypes: {
    type: {
      control: 'select',
      options: ['text', 'email', 'password', 'number', 'url', 'tel', 'search']
    },
    disabled: { control: 'boolean' }
  }
} satisfies Meta<typeof Input>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <div className="w-72">
      <Input {...args} />
    </div>
  )
}

export const WithLabel: Story = {
  render: () => (
    <div className="flex w-72 flex-col gap-2">
      <Label htmlFor="email">Email</Label>
      <Input id="email" type="email" placeholder="you@example.com" />
    </div>
  )
}

export const Disabled: Story = {
  args: { disabled: true, value: 'Read only' },
  render: args => (
    <div className="w-72">
      <Input {...args} />
    </div>
  )
}

export const Invalid: Story = {
  render: () => (
    <div className="w-72">
      <Input aria-invalid placeholder="Invalid input" />
    </div>
  )
}
