defmodule BullX.EventBus.CommandTarget.SystemCommands do
  @moduledoc false

  @behaviour BullX.EventBus.CommandTarget

  alias BullX.EventBus.ChannelAdapter
  alias BullX.EventBus.CommandTarget.Registry
  alias BullX.EventBus.TargetSession

  @command_list_ref "bullx.system.command_list"
  @status_ref "bullx.system.status"

  @impl BullX.EventBus.CommandTarget
  def handle(%{target_ref: @command_list_ref} = invocation, side_channel_entry) do
    with :ok <- reply_text(invocation, side_channel_entry, command_list_text()),
         :ok <- TargetSession.close(invocation.target_session_id) do
      :ok
    end
  end

  def handle(%{target_ref: @status_ref} = invocation, side_channel_entry) do
    with :ok <- reply_text(invocation, side_channel_entry, status_text()),
         :ok <- TargetSession.close(invocation.target_session_id) do
      :ok
    end
  end

  def handle(%{target_ref: target_ref}, _side_channel_entry) do
    {:error, {:unsupported_system_command, target_ref}}
  end

  defp command_list_text do
    lines =
      Registry.command_catalog()
      |> Enum.map(&[Registry.display_slash(&1, []), " - ", Registry.description(&1, [])])

    [BullX.I18n.t("eventbus.commands.list.header") | lines]
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  defp status_text do
    IO.iodata_to_binary([
      "BullX status:\n",
      "running: yes\n",
      "env: ",
      runtime_env(),
      "\n",
      "version: ",
      version()
    ])
  end

  defp reply_text(invocation, side_channel_entry, text) do
    case reply_channel(side_channel_entry) do
      nil ->
        :ok

      reply_channel ->
        outbound = %{
          "id" => idempotency_key(invocation, side_channel_entry, reply_channel),
          "op" => "send",
          "content" => [%{"kind" => "text", "body" => %{"text" => text}}]
        }

        case ChannelAdapter.deliver(reply_channel, outbound) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp reply_channel(%{cloud_event: %{"data" => %{"reply_channel" => reply_channel}}}),
    do: reply_channel

  defp reply_channel(_side_channel_entry), do: nil

  defp idempotency_key(invocation, side_channel_entry, reply_channel) do
    command_name =
      get_in(side_channel_entry, [:cloud_event, "data", "routing_facts", "command_name"]) ||
        invocation.target_ref

    [
      side_channel_entry.id,
      invocation.target_ref,
      command_name,
      stable_reply_channel_identity(reply_channel)
    ]
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
    |> case do
      hash when is_binary(hash) -> hash
      {:error, reason} -> raise ArgumentError, "command idempotency key failed: #{reason}"
    end
  end

  defp stable_reply_channel_identity(reply_channel) do
    reply_channel
    |> stringify_keys()
    |> Map.take(["adapter", "channel_id", "scope_id", "thread_id", "reply_to_external_id"])
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [key, value] end)
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp runtime_env do
    :bullx
    |> Application.get_env(:runtime_env, :prod)
    |> Atom.to_string()
  end

  defp version do
    case Application.spec(:bullx, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _version -> "unknown"
    end
  end
end
