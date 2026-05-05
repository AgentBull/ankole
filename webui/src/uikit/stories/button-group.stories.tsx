import { RiArrowLeftSLine, RiArrowRightSLine, RiBold, RiItalic, RiUnderline } from "@remixicon/react"
import type { Meta, StoryObj } from "@storybook/react"

import { Button } from "@/uikit/components/button"
import { ButtonGroup, ButtonGroupSeparator, ButtonGroupText } from "@/uikit/components/button-group"

const meta = {
  title: "Components/ButtonGroup",
  component: ButtonGroup,
  argTypes: {
    orientation: {
      control: "radio",
      options: ["horizontal", "vertical"],
    },
  },
} satisfies Meta<typeof ButtonGroup>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <ButtonGroup {...args}>
      <Button variant="outline">Previous</Button>
      <Button variant="outline">Next</Button>
    </ButtonGroup>
  ),
}

export const Vertical: Story = {
  args: { orientation: "vertical" },
  render: args => (
    <ButtonGroup {...args}>
      <Button variant="outline">Top</Button>
      <Button variant="outline">Middle</Button>
      <Button variant="outline">Bottom</Button>
    </ButtonGroup>
  ),
}

export const WithIcons: Story = {
  render: () => (
    <ButtonGroup>
      <Button variant="outline" aria-label="Bold">
        <RiBold />
      </Button>
      <Button variant="outline" aria-label="Italic">
        <RiItalic />
      </Button>
      <Button variant="outline" aria-label="Underline">
        <RiUnderline />
      </Button>
    </ButtonGroup>
  ),
}

export const WithSeparator: Story = {
  render: () => (
    <ButtonGroup>
      <Button variant="outline" aria-label="Previous">
        <RiArrowLeftSLine />
      </Button>
      <ButtonGroupSeparator />
      <ButtonGroupText>Page 1 of 10</ButtonGroupText>
      <ButtonGroupSeparator />
      <Button variant="outline" aria-label="Next">
        <RiArrowRightSLine />
      </Button>
    </ButtonGroup>
  ),
}
