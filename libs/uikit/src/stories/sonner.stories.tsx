import type { Meta, StoryObj } from '@storybook/react'
import { toast } from 'sonner'

import { Button } from '../components/button'
import { Toaster } from '../components/sonner'

const meta = {
  title: 'Components/Sonner',
  component: Toaster
} satisfies Meta<typeof Toaster>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => <Button onClick={() => toast('Event has been created')}>Show toast</Button>
}

export const Variants: Story = {
  render: () => (
    <div className="flex flex-wrap gap-3">
      <Button variant="outline" onClick={() => toast.success('Saved successfully')}>
        Success
      </Button>
      <Button variant="outline" onClick={() => toast.info('Heads up — new release')}>
        Info
      </Button>
      <Button variant="outline" onClick={() => toast.warning('Disk almost full')}>
        Warning
      </Button>
      <Button variant="outline" onClick={() => toast.error('Something went wrong')}>
        Error
      </Button>
      <Button
        variant="outline"
        onClick={() =>
          toast.promise(new Promise(resolve => setTimeout(resolve, 1500)), {
            loading: 'Loading…',
            success: 'Done',
            error: 'Failed'
          })
        }>
        Promise
      </Button>
    </div>
  )
}

export const WithAction: Story = {
  render: () => (
    <Button
      onClick={() =>
        toast('File deleted', {
          action: {
            label: 'Undo',
            onClick: () => toast.success('Restored')
          }
        })
      }>
      Show with action
    </Button>
  )
}
