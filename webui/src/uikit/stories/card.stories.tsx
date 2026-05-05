import type { Meta, StoryObj } from "@storybook/react"

import { Button } from "@/uikit/components/button"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/uikit/components/card"

const meta = {
  title: "Components/Card",
  component: Card,
  parameters: { layout: "padded" },
  argTypes: {
    size: {
      control: "radio",
      options: ["default", "sm"],
    },
  },
} satisfies Meta<typeof Card>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <Card {...args} className="w-[420px]">
      <CardHeader>
        <CardTitle>Account</CardTitle>
        <CardDescription>Manage your account settings and preferences.</CardDescription>
      </CardHeader>
      <CardContent>
        <p className="text-sm leading-relaxed text-muted-foreground">
          Configure how you sign in, get notified, and pay for your usage.
        </p>
      </CardContent>
      <CardFooter className="border-t justify-end gap-0">
        <Button variant="outline">Cancel</Button>
        <Button>Save</Button>
      </CardFooter>
    </Card>
  ),
}

export const WithAction: Story = {
  render: () => (
    <Card className="w-[420px]">
      <CardHeader className="border-b">
        <CardTitle>Subscription</CardTitle>
        <CardDescription>Renews every month.</CardDescription>
        <CardAction>
          <Button variant="ghost" size="sm">
            Manage
          </Button>
        </CardAction>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">Pro plan • $20/month</CardContent>
    </Card>
  ),
}

export const Small: Story = {
  args: { size: "sm" },
  render: args => (
    <Card {...args} className="w-[320px]">
      <CardHeader>
        <CardTitle>Compact card</CardTitle>
        <CardDescription>Reduced padding and gap.</CardDescription>
      </CardHeader>
      <CardContent className="text-sm">Useful inside dashboards and sidebars.</CardContent>
    </Card>
  ),
}
