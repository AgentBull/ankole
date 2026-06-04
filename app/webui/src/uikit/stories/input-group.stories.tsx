import { RiEyeLine, RiMailLine, RiSearchLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import {
  InputGroup,
  InputGroupAddon,
  InputGroupButton,
  InputGroupInput,
  InputGroupText,
  InputGroupTextarea
} from '@/uikit/components/input-group'

const meta = {
  title: 'Components/InputGroup',
  component: InputGroup
} satisfies Meta<typeof InputGroup>

export default meta

type Story = StoryObj<typeof meta>

export const WithIcon: Story = {
  render: () => (
    <div className="w-72">
      <InputGroup>
        <InputGroupAddon>
          <RiSearchLine />
        </InputGroupAddon>
        <InputGroupInput placeholder="Search…" />
      </InputGroup>
    </div>
  )
}

export const WithButton: Story = {
  render: () => (
    <div className="w-72">
      <InputGroup>
        <InputGroupAddon>
          <RiMailLine />
        </InputGroupAddon>
        <InputGroupInput placeholder="Email" type="email" />
        <InputGroupAddon align="inline-end">
          <InputGroupButton>Send</InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    </div>
  )
}

export const Password: Story = {
  render: () => (
    <div className="w-72">
      <InputGroup>
        <InputGroupInput type="password" placeholder="Password" />
        <InputGroupAddon align="inline-end">
          <InputGroupButton size="icon-xs" aria-label="Show password">
            <RiEyeLine />
          </InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    </div>
  )
}

export const WithText: Story = {
  render: () => (
    <div className="w-72">
      <InputGroup>
        <InputGroupAddon>
          <InputGroupText>https://</InputGroupText>
        </InputGroupAddon>
        <InputGroupInput placeholder="example.com" />
      </InputGroup>
    </div>
  )
}

export const Textarea: Story = {
  render: () => (
    <div className="w-72">
      <InputGroup>
        <InputGroupTextarea placeholder="Write a comment…" />
        <InputGroupAddon align="block-end">
          <InputGroupButton className="ml-auto">Post</InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
    </div>
  )
}
