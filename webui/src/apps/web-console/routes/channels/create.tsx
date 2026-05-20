import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "@tanstack/react-router"
import { useState } from "react"
import { Field, FieldLabel } from "@/uikit/components/field"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/uikit/components/select"
import { Skeleton } from "@/uikit/components/skeleton"
import {
  createChannelMutation,
  listChannelAdaptersOptions,
  listChannelsQueryKey,
} from "../../api/client/@tanstack/react-query.gen"
import type { ChannelAdapter } from "../../api/client/types.gen"
import { errorMessage } from "../../lib/errors"
import { ChannelForm } from "./channel-form"
import { asFormSchema, type SourceValues } from "./fields"

export function ChannelCreatePage() {
  const adapters = useQuery(listChannelAdaptersOptions())

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-6">
      <header className="flex flex-col gap-1">
        <h1 className="font-heading text-2xl leading-8">Add channel</h1>
        <p className="text-sm text-muted-foreground">Pick an adapter and enter its credentials to connect a source.</p>
      </header>

      {adapters.isPending ? (
        <FormSkeleton />
      ) : adapters.isError ? (
        <p className="text-sm text-destructive">{errorMessage(adapters.error)}</p>
      ) : adapters.data.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">No channel adapters are installed in this instance.</p>
      ) : (
        <CreateForm adapters={adapters.data.data} oidcCallbackUrlTemplate={adapters.data.oidc_callback_url_template} />
      )}
    </div>
  )
}

function CreateForm({
  adapters,
  oidcCallbackUrlTemplate,
}: {
  adapters: ChannelAdapter[]
  oidcCallbackUrlTemplate: string
}) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [adapterId, setAdapterId] = useState(adapters[0].id)
  const adapter = adapters.find(item => item.id === adapterId) ?? adapters[0]

  const create = useMutation({
    ...createChannelMutation(),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: listChannelsQueryKey() })
      navigate({ to: "/channels" })
    },
  })

  return (
    <div className="flex flex-col gap-6 border border-border bg-card p-6">
      <Field>
        <FieldLabel>Adapter</FieldLabel>
        <Select value={adapterId} onValueChange={next => setAdapterId(next ?? adapterId)}>
          <SelectTrigger className="w-full">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {adapters.map(item => (
              <SelectItem key={item.id} value={item.id}>
                {item.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </Field>

      <ChannelForm
        key={adapter.id}
        adapter={adapter}
        mode="create"
        initialSource={defaultSource(adapter)}
        oidcCallbackUrlTemplate={oidcCallbackUrlTemplate}
        submitting={create.isPending}
        submitError={create.isError ? errorMessage(create.error) : undefined}
        submitLabel="Create channel"
        onSubmit={source => create.mutate({ body: { adapter_id: adapter.id, source } })}
      />
    </div>
  )
}

function defaultSource(adapter: ChannelAdapter): SourceValues {
  return { ...(asFormSchema(adapter.form_schema).default_source ?? {}) }
}

function FormSkeleton() {
  return (
    <div className="flex flex-col gap-4 border border-border p-6">
      {[0, 1, 2, 3].map(row => (
        <Skeleton key={row} className="h-10 w-full" />
      ))}
    </div>
  )
}
