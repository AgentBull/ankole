import type { Meta, StoryObj } from '@storybook/react'

import { Button } from '../components/button'
import { Input } from '../components/input'
import { Label } from '../components/label'
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  SheetTrigger
} from '../components/sheet'

const meta = {
  title: 'Components/Sheet',
  component: Sheet
} satisfies Meta<typeof Sheet>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <Sheet>
      <SheetTrigger render={<Button variant="outline">Open sheet</Button>} />
      <SheetContent>
        <SheetHeader>
          <SheetTitle>Edit profile</SheetTitle>
          <SheetDescription>Make changes to your profile here. Save when you're done.</SheetDescription>
        </SheetHeader>
        <div className="grid gap-4 px-8 py-4">
          <div className="grid gap-2">
            <Label htmlFor="sheet-name">Name</Label>
            <Input id="sheet-name" defaultValue="Jane Doe" />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="sheet-email">Email</Label>
            <Input id="sheet-email" type="email" defaultValue="jane@ankole.dev" />
          </div>
        </div>
        <SheetFooter>
          <Button>Save</Button>
        </SheetFooter>
      </SheetContent>
    </Sheet>
  )
}

export const Sides: Story = {
  render: () => (
    <div className="grid grid-cols-2 gap-3">
      {(['top', 'right', 'bottom', 'left'] as const).map(side => (
        <Sheet key={side}>
          <SheetTrigger render={<Button variant="outline" className="capitalize" />}>{side}</SheetTrigger>
          <SheetContent side={side}>
            <SheetHeader>
              <SheetTitle className="capitalize">{side} sheet</SheetTitle>
              <SheetDescription>Slides in from the {side} edge of the viewport.</SheetDescription>
            </SheetHeader>
          </SheetContent>
        </Sheet>
      ))}
    </div>
  )
}
