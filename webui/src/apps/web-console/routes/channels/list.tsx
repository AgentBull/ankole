import { RiAddLine, RiBroadcastLine, RiDeleteBinLine, RiPencilLine } from "@remixicon/react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link } from "@tanstack/react-router"
import { useState } from "react"
import { Badge } from "@/uikit/components/badge"
import { Button } from "@/uikit/components/button"
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/uikit/components/dialog"
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/uikit/components/empty"
import { Skeleton } from "@/uikit/components/skeleton"
import { Spinner } from "@/uikit/components/spinner"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/uikit/components/table"
import {
  deleteChannelMutation,
  listChannelsOptions,
  listChannelsQueryKey,
} from "../../api/client/@tanstack/react-query.gen"
import type { Channel } from "../../api/client/types.gen"
import { errorMessage } from "../../lib/errors"

export function ChannelsListPage() {
  const channels = useQuery(listChannelsOptions())

  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-6">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div className="flex flex-col gap-1">
          <h1 className="font-heading text-2xl leading-8">Channels</h1>
          <p className="text-sm text-muted-foreground">
            Connected sources that carry events between BullX and your chat platforms.
          </p>
        </div>
        <Button render={<Link to="/channels/new" />}>
          <RiAddLine />
          Add channel
        </Button>
      </header>

      {channels.isPending ? (
        <TableSkeleton />
      ) : channels.isError ? (
        <ErrorState message={errorMessage(channels.error)} onRetry={() => channels.refetch()} />
      ) : channels.data.data.length === 0 ? (
        <EmptyState />
      ) : (
        <ChannelsTable channels={channels.data.data} />
      )}
    </div>
  )
}

function ChannelsTable({ channels }: { channels: Channel[] }) {
  const [target, setTarget] = useState<Channel | null>(null)

  return (
    <>
      <div className="border border-border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Adapter</TableHead>
              <TableHead>Source ID</TableHead>
              <TableHead>Enabled</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {channels.map(channel => (
              <TableRow key={`${channel.adapter_id}/${channel.id}`}>
                <TableCell className="font-medium">{channel.adapter_id}</TableCell>
                <TableCell className="font-mono text-xs">{channel.id}</TableCell>
                <TableCell>
                  <Badge variant={channel.enabled ? "default" : "secondary"}>
                    {channel.enabled ? "Enabled" : "Disabled"}
                  </Badge>
                </TableCell>
                <TableCell>
                  <Badge variant={runtimeReady(channel) ? "default" : "outline"}>
                    {runtimeReady(channel) ? "Ready" : "Not ready"}
                  </Badge>
                </TableCell>
                <TableCell>
                  <div className="flex items-center justify-end gap-1">
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label="Edit channel"
                      render={
                        <Link
                          to="/channels/$adapterId/$id/edit"
                          params={{ adapterId: channel.adapter_id, id: channel.id }}
                        />
                      }>
                      <RiPencilLine />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label="Delete channel"
                      onClick={() => setTarget(channel)}>
                      <RiDeleteBinLine />
                    </Button>
                  </div>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <DeleteChannelDialog target={target} onClose={() => setTarget(null)} />
    </>
  )
}

function DeleteChannelDialog({ target, onClose }: { target: Channel | null; onClose: () => void }) {
  const queryClient = useQueryClient()
  const remove = useMutation({
    ...deleteChannelMutation(),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: listChannelsQueryKey() })
      onClose()
    },
  })

  return (
    <Dialog open={target !== null} onOpenChange={open => (open ? null : onClose())}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Delete channel</DialogTitle>
          <DialogDescription>
            Remove{" "}
            <span className="font-mono">
              {target?.adapter_id}/{target?.id}
            </span>
            ? Its transport stops and the configuration is erased. This cannot be undone.
          </DialogDescription>
        </DialogHeader>
        {remove.isError ? <p className="text-sm text-destructive">{errorMessage(remove.error)}</p> : null}
        <DialogFooter>
          <DialogClose render={<Button variant="outline">Cancel</Button>} />
          <Button
            variant="destructive"
            disabled={remove.isPending}
            onClick={() => {
              if (target) {
                remove.mutate({ path: { adapter_id: target.adapter_id, id: target.id } })
              }
            }}>
            {remove.isPending ? <Spinner /> : null}
            Delete
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function runtimeReady(channel: Channel): boolean {
  const runtime = channel.config.runtime
  return Boolean(runtime && typeof runtime === "object" && (runtime as Record<string, unknown>).ready)
}

function TableSkeleton() {
  return (
    <div className="flex flex-col gap-2 border border-border p-4">
      {[0, 1, 2].map(row => (
        <Skeleton key={row} className="h-10 w-full" />
      ))}
    </div>
  )
}

function EmptyState() {
  return (
    <Empty className="border border-dashed border-border">
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <RiBroadcastLine className="size-5" />
        </EmptyMedia>
        <EmptyTitle>No channels yet</EmptyTitle>
        <EmptyDescription>
          Connect Telegram, Discord, or Feishu so agents can send and receive messages.
        </EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button render={<Link to="/channels/new" />}>
          <RiAddLine />
          Add channel
        </Button>
      </EmptyContent>
    </Empty>
  )
}

function ErrorState({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <Empty className="border border-dashed border-destructive/50">
      <EmptyHeader>
        <EmptyTitle>Couldn't load channels</EmptyTitle>
        <EmptyDescription>{message}</EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button variant="outline" onClick={onRetry}>
          Try again
        </Button>
      </EmptyContent>
    </Empty>
  )
}
