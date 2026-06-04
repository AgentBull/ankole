import type { Meta, StoryObj } from '@storybook/react'

import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectSeparator,
  SelectTrigger,
  SelectValue
} from '@/uikit/components/select'

const meta = {
  title: 'Components/Select',
  component: Select
} satisfies Meta<typeof Select>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <Select>
      <SelectTrigger className="w-56">
        <SelectValue placeholder="Pick a fruit" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="apple">Apple</SelectItem>
        <SelectItem value="banana">Banana</SelectItem>
        <SelectItem value="grape">Grape</SelectItem>
        <SelectItem value="orange">Orange</SelectItem>
      </SelectContent>
    </Select>
  )
}

export const Grouped: Story = {
  render: () => (
    <Select>
      <SelectTrigger className="w-56">
        <SelectValue placeholder="Pick something" />
      </SelectTrigger>
      <SelectContent>
        <SelectGroup>
          <SelectLabel>Fruits</SelectLabel>
          <SelectItem value="apple">Apple</SelectItem>
          <SelectItem value="banana">Banana</SelectItem>
        </SelectGroup>
        <SelectSeparator />
        <SelectGroup>
          <SelectLabel>Vegetables</SelectLabel>
          <SelectItem value="carrot">Carrot</SelectItem>
          <SelectItem value="celery">Celery</SelectItem>
        </SelectGroup>
      </SelectContent>
    </Select>
  )
}

export const Small: Story = {
  render: () => (
    <Select>
      <SelectTrigger size="sm" className="w-44">
        <SelectValue placeholder="Small" />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="one">One</SelectItem>
        <SelectItem value="two">Two</SelectItem>
        <SelectItem value="three">Three</SelectItem>
      </SelectContent>
    </Select>
  )
}
