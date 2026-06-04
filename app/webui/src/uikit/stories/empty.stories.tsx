import { RiInboxLine, RiSearchLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import { Button } from '@/uikit/components/button'
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from '@/uikit/components/empty'

const meta = {
  title: 'Components/Empty',
  component: Empty,
  parameters: { layout: 'padded' }
} satisfies Meta<typeof Empty>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <Empty className="border">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <RiInboxLine />
        </EmptyMedia>
        <EmptyTitle>No notifications</EmptyTitle>
        <EmptyDescription>You're all caught up.</EmptyDescription>
      </EmptyHeader>
    </Empty>
  )
}

export const WithAction: Story = {
  render: () => (
    <Empty className="border">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <RiSearchLine />
        </EmptyMedia>
        <EmptyTitle>No results</EmptyTitle>
        <EmptyDescription>Try adjusting your filters or check back later.</EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button variant="outline">Reset filters</Button>
      </EmptyContent>
    </Empty>
  )
}
