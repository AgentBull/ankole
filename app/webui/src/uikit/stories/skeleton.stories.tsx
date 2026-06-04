import type { Meta, StoryObj } from '@storybook/react'

import { Skeleton } from '@/uikit/components/skeleton'

const meta = {
  title: 'Components/Skeleton',
  component: Skeleton
} satisfies Meta<typeof Skeleton>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => <Skeleton className="h-4 w-48" />
}

export const Card: Story = {
  render: () => (
    <div className="flex w-72 flex-col gap-4">
      <Skeleton className="h-32 w-full" />
      <div className="flex flex-col gap-2">
        <Skeleton className="h-4 w-3/4" />
        <Skeleton className="h-4 w-1/2" />
      </div>
    </div>
  )
}

export const Avatar: Story = {
  render: () => (
    <div className="flex items-center gap-3">
      <Skeleton className="size-10 rounded-full" />
      <div className="flex flex-col gap-2">
        <Skeleton className="h-3 w-32" />
        <Skeleton className="h-3 w-24" />
      </div>
    </div>
  )
}
