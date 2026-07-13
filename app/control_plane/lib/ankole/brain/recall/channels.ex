defmodule Ankole.Brain.Recall.Channels do
  @moduledoc false

  alias Ankole.Brain.Scope
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Channel

  @spec allowed(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def allowed(%Scope{} = scope, channel_scope, requested_channel_id \\ nil) do
    channels =
      case channel_scope do
        "current_channel" -> current_channel_ids(scope)
        "all_channels" -> all_channel_ids(scope)
      end

    case requested_channel_id do
      nil ->
        {:ok, channels}

      channel_id ->
        if channel_id in channels,
          do: {:ok, [channel_id]},
          else: {:error, :brain_channel_not_visible}
    end
  end

  @spec visible?(Scope.t(), String.t()) :: boolean()
  def visible?(%Scope{} = scope, channel_id) when is_binary(channel_id) do
    channel_id in all_channel_ids(scope)
  end

  defp current_channel_ids(%Scope{current_channel: %{id: id}}), do: [id]
  defp current_channel_ids(%Scope{}), do: []

  defp all_channel_ids(%Scope{} = scope) do
    visible = SignalsGateway.visible_channels(scope.owner_uid)

    case scope do
      %Scope{writable_store_key: "public", current_channel: current_channel} ->
        public_ids = visible |> Enum.reject(&dm_channel?/1) |> Enum.map(& &1.id)

        case current_channel do
          %{id: current_id} -> Enum.uniq([current_id | public_ids])
          nil -> public_ids
        end

      %Scope{writable_store_key: "dm:" <> _peer_uid, current_channel: %{id: current_id}} ->
        public_ids = visible |> Enum.reject(&dm_channel?/1) |> Enum.map(& &1.id)
        Enum.uniq([current_id | public_ids])

      %Scope{readable_store_keys: :all} ->
        Enum.map(visible, & &1.id)

      %Scope{} ->
        current_channel_ids(scope)
    end
  end

  defp dm_channel?(%Channel{kind: :im_dm}), do: true
  defp dm_channel?(%Channel{}), do: false
end
