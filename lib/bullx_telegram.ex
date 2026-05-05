defmodule BullXTelegram do
  @moduledoc """
  Telegram Gateway adapter namespace.

  Telegram is a first-class Gateway integration, not a separate OTP
  application. The modules under this namespace translate Telegram Bot API
  updates and delivery calls at the Gateway boundary while keeping Telegram
  actor identities channel-local.
  """

  @adapter :telegram

  @spec adapter_id() :: :telegram
  def adapter_id, do: @adapter

  @spec channel(String.t()) :: BullXGateway.Delivery.channel()
  def channel(channel_id) when is_binary(channel_id), do: {@adapter, channel_id}
end
