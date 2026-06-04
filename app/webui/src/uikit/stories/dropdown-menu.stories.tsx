import { RiDeleteBinLine, RiFileCopyLine, RiSettings3Line, RiUser3Line } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'
import { useState } from 'react'

import { Button } from '@/uikit/components/button'
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger
} from '@/uikit/components/dropdown-menu'

const meta = {
  title: 'Components/DropdownMenu',
  component: DropdownMenu
} satisfies Meta<typeof DropdownMenu>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button variant="outline">Open menu</Button>} />
      <DropdownMenuContent>
        <DropdownMenuLabel>My account</DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuItem>
            <RiUser3Line />
            Profile
            <DropdownMenuShortcut>⌘P</DropdownMenuShortcut>
          </DropdownMenuItem>
          <DropdownMenuItem>
            <RiSettings3Line />
            Settings
            <DropdownMenuShortcut>⌘S</DropdownMenuShortcut>
          </DropdownMenuItem>
          <DropdownMenuItem>
            <RiFileCopyLine />
            Duplicate
          </DropdownMenuItem>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive">
          <RiDeleteBinLine />
          Delete
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

export const WithCheckbox: Story = {
  render: function Render() {
    const [bookmarks, setBookmarks] = useState(true)
    const [urls, setUrls] = useState(false)
    return (
      <DropdownMenu>
        <DropdownMenuTrigger render={<Button variant="outline">View options</Button>} />
        <DropdownMenuContent>
          <DropdownMenuLabel>Appearance</DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuCheckboxItem checked={bookmarks} onCheckedChange={setBookmarks}>
            Show bookmarks
          </DropdownMenuCheckboxItem>
          <DropdownMenuCheckboxItem checked={urls} onCheckedChange={setUrls}>
            Show full URLs
          </DropdownMenuCheckboxItem>
        </DropdownMenuContent>
      </DropdownMenu>
    )
  }
}

export const WithRadio: Story = {
  render: function Render() {
    const [position, setPosition] = useState('bottom')
    return (
      <DropdownMenu>
        <DropdownMenuTrigger render={<Button variant="outline">Panel position</Button>} />
        <DropdownMenuContent>
          <DropdownMenuLabel>Panel position</DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuRadioGroup value={position} onValueChange={setPosition}>
            <DropdownMenuRadioItem value="top">Top</DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="bottom">Bottom</DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="right">Right</DropdownMenuRadioItem>
          </DropdownMenuRadioGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    )
  }
}

export const WithSubmenu: Story = {
  render: () => (
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button variant="outline">More</Button>} />
      <DropdownMenuContent>
        <DropdownMenuItem>New file</DropdownMenuItem>
        <DropdownMenuSub>
          <DropdownMenuSubTrigger>Share</DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            <DropdownMenuItem>Copy link</DropdownMenuItem>
            <DropdownMenuItem>Email</DropdownMenuItem>
            <DropdownMenuItem>Slack</DropdownMenuItem>
          </DropdownMenuSubContent>
        </DropdownMenuSub>
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive">Delete</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
