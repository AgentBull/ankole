import { RiAddLine, RiArrowRightSLine, RiDeleteBinLine } from "@remixicon/react"
import type { Meta, StoryObj } from "@storybook/react"

import { Button } from "@/uikit/components/button"

const meta = {
  title: "Components/Button",
  component: Button,
  args: {
    children: "Button",
  },
  argTypes: {
    variant: {
      control: "select",
      options: ["default", "outline", "secondary", "ghost", "destructive", "link"],
    },
    size: {
      control: "select",
      options: ["default", "xs", "sm", "lg", "icon", "icon-xs", "icon-sm", "icon-lg"],
    },
    disabled: { control: "boolean" },
  },
} satisfies Meta<typeof Button>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {}

export const Variants: Story = {
  render: () => (
    <div className="flex flex-wrap items-center gap-3">
      <Button variant="default">Default</Button>
      <Button variant="outline">Outline</Button>
      <Button variant="secondary">Secondary</Button>
      <Button variant="ghost">Ghost</Button>
      <Button variant="destructive">Destructive</Button>
      <Button variant="link">Link</Button>
    </div>
  ),
}

export const Sizes: Story = {
  render: () => (
    <div className="flex flex-wrap items-end gap-3">
      <Button size="xs">XS</Button>
      <Button size="sm">SM</Button>
      <Button size="default">Default</Button>
      <Button size="lg">LG</Button>
    </div>
  ),
}

export const IconSizes: Story = {
  render: () => (
    <div className="flex flex-wrap items-end gap-3">
      <Button size="icon-xs" aria-label="Add">
        <RiAddLine />
      </Button>
      <Button size="icon-sm" aria-label="Add">
        <RiAddLine />
      </Button>
      <Button size="icon" aria-label="Add">
        <RiAddLine />
      </Button>
      <Button size="icon-lg" aria-label="Add">
        <RiAddLine />
      </Button>
    </div>
  ),
}

export const WithIcons: Story = {
  render: () => (
    <div className="flex flex-wrap gap-3">
      <Button>
        <RiAddLine data-icon="inline-start" />
        Add item
      </Button>
      <Button variant="outline">
        Continue
        <RiArrowRightSLine data-icon="inline-end" />
      </Button>
      <Button variant="destructive">
        <RiDeleteBinLine data-icon="inline-start" />
        Delete
      </Button>
    </div>
  ),
}

export const Disabled: Story = {
  args: {
    disabled: true,
    children: "Disabled",
  },
}
