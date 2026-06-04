import type { Meta, StoryObj } from '@storybook/react'

import { Button } from '@/uikit/components/button'
import { Input } from '@/uikit/components/input'
import { Label } from '@/uikit/components/label'
import {
  Popover,
  PopoverContent,
  PopoverDescription,
  PopoverHeader,
  PopoverTitle,
  PopoverTrigger
} from '@/uikit/components/popover'

const meta = {
  title: 'Components/Popover',
  component: Popover
} satisfies Meta<typeof Popover>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <Popover>
      <PopoverTrigger render={<Button variant="outline">Open popover</Button>} />
      <PopoverContent>
        <PopoverHeader>
          <PopoverTitle>Dimensions</PopoverTitle>
          <PopoverDescription>Set the dimensions for the layer.</PopoverDescription>
        </PopoverHeader>
        <div className="grid gap-3">
          <div className="grid grid-cols-3 items-center gap-2">
            <Label htmlFor="width">Width</Label>
            <Input id="width" defaultValue="100%" className="col-span-2 h-8" />
          </div>
          <div className="grid grid-cols-3 items-center gap-2">
            <Label htmlFor="height">Height</Label>
            <Input id="height" defaultValue="25px" className="col-span-2 h-8" />
          </div>
        </div>
      </PopoverContent>
    </Popover>
  )
}
