import type { Meta, StoryObj } from '@storybook/react'

import { Label } from '@/uikit/components/label'
import { Switch } from '@/uikit/components/switch'

const meta = {
  title: 'Components/Switch',
  component: Switch,
  argTypes: {
    size: {
      control: 'radio',
      options: ['sm', 'default']
    },
    disabled: { control: 'boolean' }
  }
} satisfies Meta<typeof Switch>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const Checked: Story = {
  args: { defaultChecked: true }
}

export const Sizes: Story = {
  render: () => (
    <div className="flex items-center gap-4">
      <Switch size="sm" />
      <Switch size="default" />
    </div>
  )
}

export const Disabled: Story = {
  args: { disabled: true }
}

export const WithLabel: Story = {
  render: () => (
    <Label>
      <Switch /> Enable notifications
    </Label>
  )
}
