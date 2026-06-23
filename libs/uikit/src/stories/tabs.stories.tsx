import type { Meta, StoryObj } from '@storybook/react'

import { Tabs, TabsContent, TabsList, TabsTrigger } from '../components/tabs'

const meta = {
  title: 'Components/Tabs',
  component: Tabs,
  argTypes: {
    orientation: {
      control: 'radio',
      options: ['horizontal', 'vertical']
    }
  }
} satisfies Meta<typeof Tabs>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: args => (
    <Tabs {...args} defaultValue="account" className="w-[420px]">
      <TabsList>
        <TabsTrigger value="account">Account</TabsTrigger>
        <TabsTrigger value="password">Password</TabsTrigger>
        <TabsTrigger value="billing">Billing</TabsTrigger>
      </TabsList>
      <TabsContent value="account" className="py-4 text-sm text-muted-foreground">
        Update your account details.
      </TabsContent>
      <TabsContent value="password" className="py-4 text-sm text-muted-foreground">
        Change your password here.
      </TabsContent>
      <TabsContent value="billing" className="py-4 text-sm text-muted-foreground">
        Manage your billing subscription.
      </TabsContent>
    </Tabs>
  )
}

export const Line: Story = {
  render: () => (
    <Tabs defaultValue="overview" className="w-[420px]">
      <TabsList variant="line">
        <TabsTrigger value="overview">Overview</TabsTrigger>
        <TabsTrigger value="analytics">Analytics</TabsTrigger>
        <TabsTrigger value="reports">Reports</TabsTrigger>
      </TabsList>
      <TabsContent value="overview" className="py-4 text-sm text-muted-foreground">
        Overview content.
      </TabsContent>
      <TabsContent value="analytics" className="py-4 text-sm text-muted-foreground">
        Analytics content.
      </TabsContent>
      <TabsContent value="reports" className="py-4 text-sm text-muted-foreground">
        Reports content.
      </TabsContent>
    </Tabs>
  )
}

export const Vertical: Story = {
  args: { orientation: 'vertical' },
  render: args => (
    <Tabs {...args} defaultValue="general" className="h-48">
      <TabsList>
        <TabsTrigger value="general">General</TabsTrigger>
        <TabsTrigger value="security">Security</TabsTrigger>
        <TabsTrigger value="api">API</TabsTrigger>
      </TabsList>
      <TabsContent value="general" className="text-sm text-muted-foreground">
        General settings.
      </TabsContent>
      <TabsContent value="security" className="text-sm text-muted-foreground">
        Security settings.
      </TabsContent>
      <TabsContent value="api" className="text-sm text-muted-foreground">
        API settings.
      </TabsContent>
    </Tabs>
  )
}
