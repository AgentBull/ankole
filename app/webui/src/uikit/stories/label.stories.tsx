import type { Meta, StoryObj } from '@storybook/react'

import { Checkbox } from '@/uikit/components/checkbox'
import { Input } from '@/uikit/components/input'
import { Label } from '@/uikit/components/label'

const meta = {
  title: 'Components/Label',
  component: Label,
  args: { children: 'Label' }
} satisfies Meta<typeof Label>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const WithInput: Story = {
  render: () => (
    <div className="flex w-72 flex-col gap-2">
      <Label htmlFor="user">Username</Label>
      <Input id="user" placeholder="@bullx" />
    </div>
  )
}

export const WithCheckbox: Story = {
  render: () => (
    <Label>
      <Checkbox /> Remember me
    </Label>
  )
}
