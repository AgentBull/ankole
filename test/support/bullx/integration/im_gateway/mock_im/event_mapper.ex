defmodule BullX.Integration.IMGateway.MockIM.EventMapper do
  @moduledoc """
  Maps a mock provider event into a normalized IMGateway CloudEvent.

  Mirrors the shape produced by `Feishu.EventMapper` closely enough to exercise
  the real `BullX.IMGateway` inbound pipeline: attention is derived from whether
  the bot is @-mentioned (group) / from the chat being a DM, leading-slash text
  is surfaced as `bullx.command.invoked`, and `channel.adapter` is pinned to
  `"mock"` so `ChannelAdapter.validate_message_adapter/2` accepts the event.
  """

  @adapter "mock"
  @ref_kind "mock.message"

  @doc "Adapter id this mapper mints events for (must match the plugin extension id)."
  def adapter_id, do: @adapter

  def build(source, %{kind: kind} = input) when is_map(source) do
    {:ok,
     %{
       "id" => input.occurrence_id,
       "source" => "mock://#{source_id(source)}/#{input.chat_id}",
       "type" => event_type(kind),
       "time" => DateTime.to_iso8601(DateTime.utc_now()),
       "data" => data(source, input)
     }}
  end

  defp data(source, input) do
    base = %{
      "content" => content(input),
      "channel" => channel(source, input),
      "scope" =>
        %{"id" => input.chat_id, "thread_id" => input[:thread_id], "realm_id" => input[:realm_id]}
        |> reject_nil_values(),
      "actor" => actor(input),
      "refs" => [%{"kind" => @ref_kind, "id" => input.message_id}],
      "reply_address" => reply_address(source, input),
      "routing_facts" => routing_facts(input),
      "raw_ref" => %{
        "kind" => @ref_kind,
        "id" => input.message_id,
        "message_id" => input.message_id
      }
    }

    maybe_put_command(base, input)
  end

  defp content(%{kind: :command} = input), do: [text_block(command_content(input))]
  defp content(%{kind: :recall}), do: [text_block("[message recalled]")]
  defp content(%{kind: :delete}), do: [text_block("[message deleted]")]
  defp content(input), do: [text_block(input.text || "")]

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp channel(source, input) do
    %{
      "adapter" => @adapter,
      "id" => source_id(source),
      "kind" => Atom.to_string(input.chat_kind),
      "trusted_realm_by_default" => true
    }
  end

  defp actor(%{sender: sender}) do
    %{
      "external_account_id" => sender.id,
      "display_name" => sender[:display_name] || sender.id
    }
  end

  defp reply_address(source, input) do
    %{
      "adapter" => @adapter,
      "channel_id" => source_id(source),
      "scope_id" => input.chat_id,
      "scope_kind" => Atom.to_string(input.chat_kind),
      "realm_id" => input[:realm_id],
      "reply_to_external_id" => input.message_id,
      "delivery_mode" => input[:delivery_mode] || "send"
    }
    |> reject_nil_values()
  end

  defp routing_facts(%{kind: :command} = input) do
    %{
      "command_name" => input.command.name,
      "command_surface" => "slash_text",
      "command_args_kind" => command_args_kind(input.command)
    }
  end

  defp routing_facts(input) do
    %{
      "attention_reason" => attention_reason(input),
      "group_message_mode" => input[:group_message_mode] || "addressed_only",
      "realm_id" => input[:realm_id],
      "mentions" => mentions(input)
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  # DM is always addressed; in a group the bot must be @-mentioned to be addressed.
  defp attention_reason(%{chat_kind: :dm}), do: "dm"
  defp attention_reason(%{mention_bot: true}), do: "mention"
  defp attention_reason(_input), do: "unaddressed"

  defp mentions(%{mention_bot: true} = input),
    do: input[:mentions] || [%{"id" => "bot", "username" => "bot"}]

  defp mentions(input), do: input[:mentions] || []

  defp maybe_put_command(data, %{kind: :command} = input) do
    Map.put(data, "command", %{
      "name" => input.command.name,
      "args_text" => input.command[:args_text] || "",
      "args_kind" => command_args_kind(input.command),
      "surface" => "slash_text"
    })
  end

  defp maybe_put_command(data, _input), do: data

  defp command_content(%{command: %{args_text: args}}) when is_binary(args) and args != "",
    do: args

  defp command_content(%{command: %{name: name}}), do: "/" <> name

  defp command_args_kind(%{args_text: args}) when is_binary(args) and args != "", do: "text"
  defp command_args_kind(_command), do: "none"

  defp event_type(:message), do: "bullx.message.received"
  defp event_type(:edit), do: "bullx.message.edited"
  defp event_type(:recall), do: "bullx.message.recalled"
  defp event_type(:delete), do: "bullx.message.deleted"
  defp event_type(:command), do: "bullx.command.invoked"

  defp source_id(%{"id" => id}) when is_binary(id), do: id
  defp source_id(%{id: id}) when is_binary(id), do: id
  defp source_id(_source), do: "default"
end
