import type { Meta, StoryObj } from '@storybook/react'

import { Label } from '../components/label'
import { RadioGroup, RadioGroupItem } from '../components/radio-group'

const meta = {
  title: 'Components/RadioGroup',
  component: RadioGroup
} satisfies Meta<typeof RadioGroup>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <RadioGroup defaultValue="comfortable" className="w-64">
      <Label>
        <RadioGroupItem value="default" /> Default
      </Label>
      <Label>
        <RadioGroupItem value="comfortable" /> Comfortable
      </Label>
      <Label>
        <RadioGroupItem value="compact" /> Compact
      </Label>
    </RadioGroup>
  )
}

export const Disabled: Story = {
  render: () => (
    <RadioGroup defaultValue="one" className="w-64">
      <Label>
        <RadioGroupItem value="one" /> One
      </Label>
      <Label>
        <RadioGroupItem value="two" disabled /> Two (disabled)
      </Label>
    </RadioGroup>
  )
}
