import type { Meta, StoryObj } from '@storybook/react'

import { Checkbox } from '@/uikit/components/checkbox'
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSeparator,
  FieldSet,
  FieldTitle
} from '@/uikit/components/field'
import { Input } from '@/uikit/components/input'
import { Textarea } from '@/uikit/components/textarea'

const meta = {
  title: 'Components/Field',
  component: Field,
  parameters: { layout: 'padded' }
} satisfies Meta<typeof Field>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <div className="w-96">
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor="email">Email</FieldLabel>
          <Input id="email" type="email" placeholder="you@example.com" />
          <FieldDescription>We'll never share your email.</FieldDescription>
        </Field>
        <Field>
          <FieldLabel htmlFor="bio">Bio</FieldLabel>
          <Textarea id="bio" placeholder="Tell us about yourself" />
        </Field>
      </FieldGroup>
    </div>
  )
}

export const Horizontal: Story = {
  render: () => (
    <div className="w-96">
      <FieldGroup>
        <Field orientation="horizontal">
          <Checkbox id="terms" />
          <FieldContent>
            <FieldTitle>Accept terms</FieldTitle>
            <FieldDescription>I agree to the terms of service.</FieldDescription>
          </FieldContent>
        </Field>
      </FieldGroup>
    </div>
  )
}

export const WithError: Story = {
  render: () => (
    <div className="w-96">
      <Field data-invalid>
        <FieldLabel htmlFor="username">Username</FieldLabel>
        <Input id="username" aria-invalid defaultValue="x" />
        <FieldError errors={[{ message: 'Must be at least 3 characters' }]} />
      </Field>
    </div>
  )
}

export const WithLegend: Story = {
  render: () => (
    <FieldSet className="w-96">
      <FieldLegend>Notifications</FieldLegend>
      <FieldDescription>Choose what you want to hear about.</FieldDescription>
      <FieldGroup>
        <Field orientation="horizontal">
          <Checkbox defaultChecked />
          <FieldContent>
            <FieldTitle>Releases</FieldTitle>
            <FieldDescription>Notified about new releases.</FieldDescription>
          </FieldContent>
        </Field>
        <FieldSeparator />
        <Field orientation="horizontal">
          <Checkbox />
          <FieldContent>
            <FieldTitle>Mentions</FieldTitle>
            <FieldDescription>When someone mentions you.</FieldDescription>
          </FieldContent>
        </Field>
      </FieldGroup>
    </FieldSet>
  )
}
