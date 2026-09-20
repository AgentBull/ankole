defmodule Ankole.SignalsGateway.ActorRuntime.Transport.Reply do
  @moduledoc """
  Deferred acknowledgement of one inbound Worker Channel message.

  The Worker Channel answers a `durable` or `control` message only after the
  domain owner has committed it, but the commit runs in another process. The
  channel hands that process a reply handle; the process calls `done/2` once.
  The reply itself is sent by the channel process, because the wire
  acknowledgement carries the stream's cumulative sequence and remaining
  credits, which only the channel knows. A `nil` handle (local and ZeroMQ
  routes) is a no-op.
  """

  @type t ::
          nil
          | %{
              ref: Phoenix.Socket.socket_ref(),
              channel: pid(),
              stream: :control | :durable | :telemetry,
              seq: pos_integer(),
              bytes: non_neg_integer()
            }

  @spec done(t(), term()) :: :ok
  def done(nil, _result), do: :ok

  def done(%{ref: ref, channel: channel, stream: stream, seq: seq, bytes: bytes}, result) do
    send(channel, {:reply_done, ref, stream, seq, bytes, result})
    :ok
  end
end
