import { RiArrowRightSLine, RiFileTextLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import { Avatar, AvatarFallback } from '@/uikit/components/avatar'
import { Button } from '@/uikit/components/button'
import {
  Item,
  ItemActions,
  ItemContent,
  ItemDescription,
  ItemGroup,
  ItemMedia,
  ItemSeparator,
  ItemTitle
} from '@/uikit/components/item'

const meta = {
  title: 'Components/Item',
  component: Item,
  parameters: { layout: 'padded' },
  argTypes: {
    variant: {
      control: 'select',
      options: ['default', 'outline', 'muted']
    },
    size: {
      control: 'select',
      options: ['default', 'sm', 'xs']
    }
  }
} satisfies Meta<typeof Item>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <Item {...args} className="w-96">
      <ItemMedia variant="icon">
        <RiFileTextLine />
      </ItemMedia>
      <ItemContent>
        <ItemTitle>Project brief</ItemTitle>
        <ItemDescription>Last edited 3 hours ago.</ItemDescription>
      </ItemContent>
      <ItemActions>
        <Button variant="ghost" size="icon-sm" aria-label="Open">
          <RiArrowRightSLine />
        </Button>
      </ItemActions>
    </Item>
  )
}

export const WithAvatar: Story = {
  render: () => (
    <Item variant="outline" className="w-96">
      <ItemMedia>
        <Avatar>
          <AvatarFallback>JD</AvatarFallback>
        </Avatar>
      </ItemMedia>
      <ItemContent>
        <ItemTitle>Jane Doe</ItemTitle>
        <ItemDescription>jane@bullx.dev</ItemDescription>
      </ItemContent>
      <ItemActions>
        <Button size="sm" variant="outline">
          Invite
        </Button>
      </ItemActions>
    </Item>
  )
}

export const Group: Story = {
  render: () => (
    <ItemGroup className="w-96">
      <Item variant="outline">
        <ItemContent>
          <ItemTitle>First item</ItemTitle>
          <ItemDescription>Some description.</ItemDescription>
        </ItemContent>
      </Item>
      <ItemSeparator />
      <Item variant="outline">
        <ItemContent>
          <ItemTitle>Second item</ItemTitle>
          <ItemDescription>Some description.</ItemDescription>
        </ItemContent>
      </Item>
      <ItemSeparator />
      <Item variant="outline">
        <ItemContent>
          <ItemTitle>Third item</ItemTitle>
          <ItemDescription>Some description.</ItemDescription>
        </ItemContent>
      </Item>
    </ItemGroup>
  )
}
