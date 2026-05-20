import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useNavigate, useParams } from "@tanstack/react-router"
import { Skeleton } from "@/uikit/components/skeleton"
import {
  getChannelOptions,
  getChannelQueryKey,
  listChannelAdaptersOptions,
  listChannelsQueryKey,
  updateChannelMutation,
} from "../../api/client/@tanstack/react-query.gen"
import type { Channel, ChannelAdapter } from "../../api/client/types.gen"
import { errorMessage } from "../../lib/errors"
import { ChannelForm } from "./channel-form"
import { asFormSchema, getPath, type SourceValues, schemaFields, setPath, sourceFieldPath } from "./fields"

export function ChannelEditPage() {
  const { adapterId, id } = useParams({ from: "/channels/$adapterId/$id/edit" })
  const channel = useQuery(getChannelOptions({ path: { adapter_id: adapterId, id } }))
  const adapters = useQuery(listChannelAdaptersOptions())

  return (
    <div className="mx-auto flex w-full max-w-3xl flex-col gap-6">
      <header className="flex flex-col gap-1">
        <h1 className="font-heading text-2xl leading-8">Edit channel</h1>
        <p className="font-mono text-sm text-muted-foreground">
          {adapterId}/{id}
        </p>
      </header>

      {channel.isPending || adapters.isPending ? (
        <FormSkeleton />
      ) : channel.isError ? (
        <p className="text-sm text-destructive">{errorMessage(channel.error, "Channel not found.")}</p>
      ) : adapters.isError ? (
        <p className="text-sm text-destructive">{errorMessage(adapters.error)}</p>
      ) : (
        <ResolvedEdit
          channel={channel.data}
          adapter={adapters.data.data.find(item => item.id === adapterId)}
          oidcCallbackUrlTemplate={adapters.data.oidc_callback_url_template}
        />
      )}
    </div>
  )
}

function ResolvedEdit({
  channel,
  adapter,
  oidcCallbackUrlTemplate,
}: {
  channel: Channel
  adapter: ChannelAdapter | undefined
  oidcCallbackUrlTemplate: string
}) {
  if (!adapter) {
    return (
      <p className="text-sm text-muted-foreground">This channel's adapter is not installed, so it can't be edited.</p>
    )
  }

  return <EditForm channel={channel} adapter={adapter} oidcCallbackUrlTemplate={oidcCallbackUrlTemplate} />
}

function EditForm({
  channel,
  adapter,
  oidcCallbackUrlTemplate,
}: {
  channel: Channel
  adapter: ChannelAdapter
  oidcCallbackUrlTemplate: string
}) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  const update = useMutation({
    ...updateChannelMutation(),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: listChannelsQueryKey() })
      queryClient.invalidateQueries({
        queryKey: getChannelQueryKey({ path: { adapter_id: channel.adapter_id, id: channel.id } }),
      })
      navigate({ to: "/channels" })
    },
  })

  return (
    <div className="border border-border bg-card p-6">
      <ChannelForm
        key={`${channel.adapter_id}/${channel.id}`}
        adapter={adapter}
        mode="edit"
        initialSource={editSource(adapter, channel)}
        existingConfig={channel.config}
        oidcCallbackUrlTemplate={oidcCallbackUrlTemplate}
        submitting={update.isPending}
        submitError={update.isError ? errorMessage(update.error) : undefined}
        submitLabel="Save changes"
        onSubmit={source =>
          update.mutate({ path: { adapter_id: channel.adapter_id, id: channel.id }, body: { source } })
        }
      />
    </div>
  )
}

function editSource(adapter: ChannelAdapter, channel: Channel): SourceValues {
  let source: SourceValues = { id: channel.id, enabled: channel.enabled }

  for (const field of schemaFields(asFormSchema(adapter.form_schema))) {
    if (field.kind === "secret") {
      continue
    }
    const path = sourceFieldPath(field)
    const value = getPath(channel.config, path)
    if (value !== undefined) {
      source = setPath(source, path, value)
    }
  }

  return source
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
