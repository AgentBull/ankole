defmodule Ankole.Sessions.Transport.Reply do
  @moduledoc """
  Deferred acknowledgement of one inbound Worker Channel message.

  The Worker Channel answers a `durable` or `control` message only after the
  domain owner has taken it. Environment messages are forwarded to the Driver.
  Job tasks and Channel lifecycle writes
  call `done/2` once with the reply handle.
  The reply itself is sent by the channel process, because the wire
  acknowledgement carries the stream's cumulative sequence and remaining
  credits, which only the channel knows. A `nil` handle (a local test route)
  is a no-op.
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
