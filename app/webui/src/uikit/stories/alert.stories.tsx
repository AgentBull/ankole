import { RiCloseLine, RiErrorWarningLine, RiInformationLine } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import { Alert, AlertAction, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Button } from '@/uikit/components/button'

const meta = {
  title: 'Components/Alert',
  component: Alert,
  parameters: { layout: 'padded' },
  argTypes: {
    variant: {
      control: 'radio',
      options: ['default', 'destructive']
    }
  }
} satisfies Meta<typeof Alert>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <Alert {...args} className="max-w-lg">
      <RiInformationLine />
      <AlertTitle>Heads up!</AlertTitle>
      <AlertDescription>You can add components to your app using the CLI.</AlertDescription>
    </Alert>
  )
}

export const Destructive: Story = {
  args: { variant: 'destructive' },
  render: args => (
    <Alert {...args} className="max-w-lg">
      <RiErrorWarningLine />
      <AlertTitle>Something went wrong</AlertTitle>
      <AlertDescription>Your session has expired. Please refresh the page.</AlertDescription>
    </Alert>
  )
}

export const WithAction: Story = {
  render: () => (
    <Alert className="max-w-lg">
      <RiInformationLine />
      <AlertTitle>New version available</AlertTitle>
      <AlertDescription>A new version of the app is ready to install.</AlertDescription>
      <AlertAction>
        <Button variant="ghost" size="icon-sm" aria-label="Dismiss">
          <RiCloseLine />
        </Button>
      </AlertAction>
    </Alert>
  )
}

export const TitleOnly: Story = {
  render: () => (
    <Alert className="max-w-lg">
      <AlertTitle>This is a title-only alert</AlertTitle>
    </Alert>
  )
}
