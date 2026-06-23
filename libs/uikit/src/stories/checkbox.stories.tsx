import type { Meta, StoryObj } from '@storybook/react'

import { Checkbox } from '../components/checkbox'
import { Label } from '../components/label'

const meta = {
  title: 'Components/Checkbox',
  component: Checkbox,
  argTypes: {
    disabled: { control: 'boolean' },
    defaultChecked: { control: 'boolean' }
  }
} satisfies Meta<typeof Checkbox>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const Checked: Story = {
  args: { defaultChecked: true }
}

export const Disabled: Story = {
  args: { disabled: true }
}

export const WithLabel: Story = {
  render: () => (
    <Label>
      <Checkbox /> Accept terms and conditions
    </Label>
  )
}

export const Group: Story = {
  render: () => (
    <div className="flex flex-col gap-3">
      <Label>
        <Checkbox defaultChecked /> Email notifications
      </Label>
      <Label>
        <Checkbox /> SMS notifications
      </Label>
      <Label>
        <Checkbox disabled /> Push notifications (coming soon)
      </Label>
    </div>
  )
}
