import type { Meta, StoryObj } from '@storybook/react'

import { Progress, ProgressLabel, ProgressValue } from '@/uikit/components/progress'

const meta = {
  title: 'Components/Progress',
  component: Progress,
  argTypes: {
    value: { control: { type: 'range', min: 0, max: 100, step: 1 } }
  }
} satisfies Meta<typeof Progress>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  args: { value: 60 },
  render: args => (
    <div className="w-72">
      <Progress {...args} />
    </div>
  )
}

export const WithLabel: Story = {
  args: { value: 42 },
  render: args => (
    <div className="w-72">
      <Progress {...args}>
        <ProgressLabel>Uploading</ProgressLabel>
        <ProgressValue />
      </Progress>
    </div>
  )
}

export const Indeterminate: Story = {
  args: { value: null },
  render: args => (
    <div className="w-72">
      <Progress {...args} />
    </div>
  )
}
