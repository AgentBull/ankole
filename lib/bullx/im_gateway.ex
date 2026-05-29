defmodule BullX.IMGateway do
  @moduledoc """
  IM boundary for normalized provider messages.

  IMGateway stores IM room/message facts, then hands a CloudEvents mail to
  `BullX.MailBox`. Human actors written into `im_messages` are resolved through
  `BullX.Principals` before the message row is inserted.
  """

  alias BullX.IMGateway.{ChannelAdapter, Message, Room}
  alias BullX.Principals
  alias BullX.Principals.{ExternalIdentity, Principal}
  alias BullX.Repo

  @im_message_types [
    "bullx.message.received",
    "bullx.command.invoked",
    "bullx.action.submitted",
    "bullx.message.edited",
    "bullx.message.recalled",
    "bullx.message.deleted"
  ]

  @addressed_attention_reasons ~w(dm mention free_response command reply_to_bot application_command mention_text)

  @spec accept_message_event(map(), keyword()) :: {:ok, term()} | :ignore | {:error, term()}
  def accept_message_event(message_event, opts \\ [])
      when is_map(message_event) and is_list(opts) do
    case im_message_event?(message_event) do
      true -> accept_im_message_event(message_event, opts)
      false -> {:error, {:unsupported_im_message_event_type, message_event["type"]}}
    end
  end

  @spec send_message(map(), keyword()) ::
          {:ok, %{message: Message.t(), delivery: map()}}
          | {:error, %{message: Message.t(), reason: term()}}
          | {:error, term()}
  def send_message(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, room} <- upsert_room(outbound_room_attrs(attrs)),
         {:ok, message} <- insert_or_update_message(room, outbound_message_attrs(attrs, opts)) do
      deliver_outbound(message, attrs, opts)
    end
  end

  defp accept_im_message_event(message_event, opts) do
    with {:ok, actor} <- ensure_human_actor(message_event),
         {:ok, room} <- upsert_room(room_attrs(message_event)),
         {:ok, message} <- insert_or_update_message(room, message_attrs(message_event, actor)) do
      case route_im_mail(message_event, actor) do
        :route ->
          with {:ok, result} <-
                 BullX.MailBox.route(mail_for_message(message_event, message), opts) do
            {:ok, %{message: message, mailbox: result}}
          end

        {:skip, reason} ->
          {:ok, %{message: message, mailbox: reason}}
      end
    end
  end

  defp upsert_room(attrs) do
    case Repo.get_by(Room,
           provider: attrs.provider,
           source_id: attrs.source_id,
           provider_room_id: attrs.provider_room_id
         ) do
      %Room{} = room ->
        room
        |> Room.changeset(attrs)
        |> Repo.update()

      nil ->
        %Room{}
        |> Room.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, room} -> {:ok, room}
          {:error, changeset} -> existing_room_after_conflict(changeset, attrs)
        end
    end
  end

  defp existing_room_after_conflict(changeset, attrs) do
    case unique_conflict?(changeset) do
      true ->
        case Repo.get_by(Room,
               provider: attrs.provider,
               source_id: attrs.source_id,
               provider_room_id: attrs.provider_room_id
             ) do
          %Room{} = room -> {:ok, room}
          nil -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp insert_or_update_message(%Room{} = room, attrs) do
    attrs = Map.put(attrs, :room_id, room.id)

    case existing_message(room, attrs) do
      %Message{} = message ->
        message
        |> Message.changeset(attrs)
        |> Repo.update()

      nil ->
        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, message} -> {:ok, message}
          {:error, changeset} -> existing_message_after_conflict(changeset, room, attrs)
        end
    end
  end

  defp existing_message(%Room{id: room_id}, %{provider_message_id: message_id})
       when is_binary(message_id) and message_id != "" do
    Repo.get_by(Message, room_id: room_id, provider_message_id: message_id)
  end

  defp existing_message(%Room{id: room_id}, %{provider_occurrence_id: occurrence_id})
       when is_binary(occurrence_id) and occurrence_id != "" do
    Repo.get_by(Message, room_id: room_id, provider_occurrence_id: occurrence_id)
  end

  defp existing_message(_room, _attrs), do: nil

  defp existing_message_after_conflict(changeset, room, attrs) do
    case unique_conflict?(changeset) do
      true ->
        case existing_message(room, attrs) do
          %Message{} = message -> {:ok, Repo.preload(message, [:room])}
          nil -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp ensure_human_actor(%{"data" => %{"actor" => %{} = actor, "channel" => %{} = channel}}) do
    case human_actor?(actor) do
      true -> ensure_actor_principal(actor, channel)
      false -> {:ok, actor}
    end
  end

  defp ensure_human_actor(_cloud_event), do: {:ok, %{}}

  defp ensure_actor_principal(%{"principal" => %{"uid" => uid}} = actor, _channel)
       when is_binary(uid) and uid != "" do
    {:ok, actor}
  end

  defp ensure_actor_principal(actor, channel) do
    with {:ok, principal, identity} <-
           Principals.ensure_human_from_channel_actor(channel_actor_input(actor, channel)) do
      {:ok, put_actor_identity(actor, principal, identity)}
    end
  end

  defp put_actor_identity(actor, %Principal{} = principal, %ExternalIdentity{} = identity) do
    actor
    |> Map.put("principal", %{"uid" => principal.uid, "type" => Atom.to_string(principal.type)})
    |> Map.put("external_identity_id", identity.id)
    |> Map.put("external_identity_verified", Principals.channel_identity_verified?(identity))
  end

  defp room_attrs(%{"data" => data}) do
    channel = data["channel"] || %{}
    scope = data["scope"] || %{}
    routing_facts = data["routing_facts"] || %{}

    %{
      provider: provider(channel),
      source_id: source_id(channel),
      provider_realm_id:
        routing_facts["tenant_key"] || routing_facts["guild_id"] || routing_facts["chat_type"],
      provider_room_id: provider_room_id(scope, data),
      kind: room_kind(channel, routing_facts),
      title: nil,
      metadata: %{}
    }
  end

  defp message_attrs(%{} = cloud_event, actor) do
    data = cloud_event["data"] || %{}
    raw_ref = data["raw_ref"] || %{}
    content = data["content"] || []
    now = utc_now()

    %{
      direction: :inbound,
      status: message_status(cloud_event["type"]),
      provider_message_id: provider_message_id(data, cloud_event),
      provider_occurrence_id: cloud_event["id"],
      actor_kind: actor_kind(actor),
      actor_principal_uid: get_in(actor, ["principal", "uid"]),
      actor_external_identity_id: actor["external_identity_id"],
      actor_provider_id: actor["external_account_id"],
      actor: actor,
      message_kind: first_content_kind(content),
      text: primary_text(content),
      content: %{
        "blocks" => content,
        "channel" => data["channel"] || %{},
        "scope" => data["scope"] || %{},
        "refs" => data["refs"] || [],
        "routing_facts" => data["routing_facts"] || %{},
        "raw_ref" => raw_ref
      },
      attachments: [],
      mentions: mentions(data),
      reply_address: reply_address(data),
      provider_created_at: parse_time(cloud_event["time"]),
      provider_updated_at: updated_at(cloud_event["type"], cloud_event["time"]),
      received_at: now
    }
  end

  defp mail_for_message(cloud_event, %Message{} = message) do
    data = cloud_event["data"] || %{}
    mail_type = cloud_event["type"] || "bullx.message.received"

    %{
      "specversion" => "1.0",
      "id" => "#{cloud_event["source"]}:#{cloud_event["id"]}:#{mail_type}",
      "source" =>
        "bullx://im-gateway/#{provider(data["channel"] || %{})}/#{source_id(data["channel"] || %{})}",
      "type" => mail_type,
      "subject" =>
        "im://#{provider(data["channel"] || %{})}/#{source_id(data["channel"] || %{})}/#{message.room_id}/#{message.id}",
      "time" => cloud_event["time"] || DateTime.to_iso8601(utc_now()),
      "datacontenttype" => "application/json",
      "data" =>
        %{
          "source_fact" =>
            %{
              "gateway" => "im_gateway",
              "kind" => "im_message",
              "id" => message.id,
              "room_id" => message.room_id,
              "event_type" => mail_type,
              "revision" => source_revision(mail_type)
            }
            |> reject_nil_values(),
          "provider" => provider(data["channel"] || %{}),
          "source_id" => source_id(data["channel"] || %{}),
          "actor_principal_uid" => message.actor_principal_uid,
          "message_kind" => message.message_kind,
          "text_preview" => message.text,
          "conversation_context" => conversation_context(data, message),
          "content" => data["content"] || [],
          "channel" => data["channel"] || %{},
          "scope" => data["scope"] || %{},
          "actor" => message.actor,
          "refs" => data["refs"] || [],
          "reply_address" => reply_address(data),
          "command" => data["command"],
          "routing_facts" => data["routing_facts"] || %{},
          "raw_ref" => data["raw_ref"]
        }
        |> reject_nil_values()
    }
  end

  defp outbound_room_attrs(attrs) do
    reply_address = map_value(attrs, :reply_address) || %{}

    %{
      provider:
        string_value(
          reply_address["adapter"] || reply_address[:adapter] || map_value(attrs, :provider)
        ),
      source_id:
        string_value(
          reply_address["channel_id"] || reply_address[:channel_id] ||
            map_value(attrs, :source_id)
        ),
      provider_realm_id: nil,
      provider_room_id:
        string_value(
          reply_address["scope_id"] || reply_address[:scope_id] ||
            map_value(attrs, :provider_room_id)
        ),
      kind: :unknown,
      metadata: %{}
    }
  end

  defp outbound_message_attrs(attrs, _opts) do
    now = utc_now()
    content = outbound_content(attrs)

    %{
      direction: :outbound,
      status: :pending,
      provider_message_id: nil,
      provider_occurrence_id:
        string_or_nil(
          map_value(attrs, :provider_occurrence_id) || map_value(attrs, :id) ||
            BullX.Ext.gen_uuid_v7()
        ),
      actor_kind: string_value(map_value(attrs, :actor_kind) || "agent"),
      actor_principal_uid: map_value(attrs, :actor_principal_uid),
      actor_external_identity_id: map_value(attrs, :actor_external_identity_id),
      actor_provider_id: map_value(attrs, :actor_provider_id),
      actor: maybe_stringify_map(map_value(attrs, :actor)) || %{},
      message_kind: string_value(map_value(attrs, :message_kind) || first_content_kind(content)),
      text: map_value(attrs, :text) || primary_text(content),
      content: %{"blocks" => content},
      attachments: map_value(attrs, :attachments) || [],
      mentions: map_value(attrs, :mentions) || [],
      reply_address: maybe_stringify_map(map_value(attrs, :reply_address)),
      received_at: now
    }
  end

  defp deliver_outbound(%Message{} = message, attrs, opts) do
    reply_address = message.reply_address || %{}
    outbound = outbound_delivery_payload(message, attrs)

    case ChannelAdapter.deliver(reply_address, outbound, opts) do
      {:ok, delivery} ->
        with {:ok, message} <- mark_outbound_sent(message, delivery) do
          {:ok, %{message: message, delivery: delivery}}
        end

      {:error, reason} ->
        case mark_outbound_failed(message, reason) do
          {:ok, failed_message} -> {:error, %{message: failed_message, reason: reason}}
          {:error, update_reason} -> {:error, update_reason}
        end
    end
  end

  defp outbound_delivery_payload(%Message{} = message, attrs) do
    %{
      "id" => message.provider_occurrence_id || message.id,
      "op" => string_value(map_value(attrs, :op) || "send"),
      "content" => outbound_content(attrs)
    }
    |> put_optional("target_external_id", map_value(attrs, :target_external_id))
  end

  defp mark_outbound_sent(%Message{} = message, delivery) when is_map(delivery) do
    now = utc_now()

    message
    |> Message.changeset(%{
      status: outbound_success_status(delivery),
      provider_message_id: primary_external_id(delivery) || message.provider_message_id,
      sent_at: now,
      safe_error: nil
    })
    |> Repo.update()
  end

  defp mark_outbound_failed(%Message{} = message, reason) do
    message
    |> Message.changeset(%{
      status: :failed,
      safe_error: safe_error(reason)
    })
    |> Repo.update()
  end

  defp outbound_success_status(%{"status" => "recalled"}), do: :recalled
  defp outbound_success_status(_delivery), do: :sent

  defp primary_external_id(%{"primary_external_id" => id}) when is_binary(id) and id != "",
    do: id

  defp primary_external_id(%{primary_external_id: id}) when is_binary(id) and id != "", do: id

  defp primary_external_id(%{"external_message_ids" => [id | _rest]})
       when is_binary(id) and id != "",
       do: id

  defp primary_external_id(%{external_message_ids: [id | _rest]}) when is_binary(id) and id != "",
    do: id

  defp primary_external_id(_delivery), do: nil

  defp outbound_content(attrs) do
    case map_value(attrs, :content) do
      content when is_list(content) ->
        content

      %{"blocks" => blocks} when is_list(blocks) ->
        blocks

      %{blocks: blocks} when is_list(blocks) ->
        blocks

      %{} = block ->
        [block]

      _value ->
        []
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp conversation_context(data, %Message{} = message) do
    channel = data["channel"] || %{}
    scope = data["scope"] || %{}
    actor = message.actor || data["actor"] || %{}

    %{
      "scene" => %{
        "kind" => "im",
        "channel_adapter" => provider(channel),
        "channel_id" => source_id(channel),
        "channel_kind" => optional_string(channel["kind"] || channel[:kind]),
        "scope_id" => optional_string(scope["id"] || scope[:id]),
        "thread_id" => optional_string(scope["thread_id"] || scope[:thread_id])
      },
      "actor" => %{
        "principal_uid" => message.actor_principal_uid,
        "external_account_id" => actor["external_account_id"] || actor[:external_account_id]
      },
      "reply_address" => reply_address(data)
    }
  end

  defp optional_string(nil), do: ""
  defp optional_string(value), do: string_value(value)

  defp channel_actor_input(actor, channel) do
    %{
      "adapter" => provider(channel),
      "channel_id" => source_id(channel),
      "external_id" => actor["external_account_id"] || actor["id"] || actor["provider_actor_id"],
      "trusted_realm_by_default" => trusted_realm_by_default?(channel),
      "profile" =>
        %{
          "display_name" => actor["display_name"] || actor["display"],
          "avatar_url" => actor["avatar_url"]
        }
        |> reject_nil_values(),
      "metadata" => %{}
    }
  end

  defp route_im_mail(%{"type" => "bullx.message.received", "data" => data}, actor) do
    case (not human_actor?(actor) or not addressed_received?(data)) ||
           actor["external_identity_verified"] == true do
      true -> :route
      false -> {:skip, :skipped_unverified_actor}
    end
  end

  defp route_im_mail(%{"type" => "bullx.action.submitted"}, _actor),
    do: {:skip, :skipped_non_message_input}

  defp route_im_mail(%{"type" => type}, _actor)
       when type in [
              "bullx.message.edited",
              "bullx.message.recalled",
              "bullx.message.deleted"
            ],
       do: :route

  defp route_im_mail(%{"type" => "bullx.command.invoked"}, actor) do
    case not human_actor?(actor) or actor["external_identity_verified"] == true do
      true -> :route
      false -> {:skip, :skipped_unverified_actor}
    end
  end

  defp route_im_mail(_cloud_event, _actor), do: :route

  defp im_message_event?(%{"type" => type}) when type in @im_message_types, do: true
  defp im_message_event?(_event), do: false

  defp source_revision("bullx.message.edited"), do: %{"action" => "edited"}
  defp source_revision("bullx.message.recalled"), do: %{"action" => "recalled"}
  defp source_revision("bullx.message.deleted"), do: %{"action" => "deleted"}
  defp source_revision(_type), do: nil

  defp human_actor?(%{"kind" => "human"}), do: true
  defp human_actor?(%{"type" => "human"}), do: true
  defp human_actor?(%{"bot" => true}), do: false
  defp human_actor?(%{"external_account_id" => external_id}) when is_binary(external_id), do: true
  defp human_actor?(_actor), do: false

  defp actor_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp actor_kind(%{"type" => kind}) when is_binary(kind), do: kind

  defp actor_kind(%{"external_account_id" => external_id}) when is_binary(external_id),
    do: "human"

  defp actor_kind(_actor), do: "unknown"

  defp provider(channel), do: string_value(channel["adapter"] || channel[:adapter] || "unknown")
  defp source_id(channel), do: string_value(channel["id"] || channel[:id] || "default")

  defp trusted_realm_by_default?(%{"trusted_realm_by_default" => value}) when is_boolean(value),
    do: value

  defp trusted_realm_by_default?(%{trusted_realm_by_default: value}) when is_boolean(value),
    do: value

  defp trusted_realm_by_default?(_channel), do: false

  defp provider_room_id(scope, data) do
    string_value(
      scope["id"] ||
        scope[:id] ||
        get_in(data, ["reply_address", "scope_id"]) ||
        get_in(data, [:reply_address, :scope_id]) ||
        "unknown"
    )
  end

  defp room_kind(%{"kind" => "dm"}, _facts), do: :direct
  defp room_kind(%{"kind" => "direct"}, _facts), do: :direct
  defp room_kind(%{"kind" => "group"}, _facts), do: :group
  defp room_kind(%{"kind" => "channel"}, _facts), do: :channel
  defp room_kind(_channel, %{"chat_type" => "p2p"}), do: :direct
  defp room_kind(_channel, %{"chat_type" => "private"}), do: :direct
  defp room_kind(_channel, _facts), do: :unknown

  defp message_status("bullx.message.edited"), do: :edited
  defp message_status("bullx.message.recalled"), do: :recalled
  defp message_status("bullx.message.deleted"), do: :deleted
  defp message_status(_type), do: :received

  defp addressed_received?(%{"routing_facts" => %{} = facts}) do
    reason = string_value(facts["attention_reason"])
    listen_mode = string_value(facts["im_listen_mode"])

    cond do
      reason in @addressed_attention_reasons -> true
      reason == "unaddressed" and listen_mode == "all_messages" -> false
      reason == "unaddressed" -> false
      true -> true
    end
  end

  defp addressed_received?(_data), do: true

  defp provider_message_id(data, cloud_event) do
    data
    |> get_in(["raw_ref", "message_id"])
    |> first_present(get_in(data, ["reply_address", "reply_to_external_id"]))
    |> first_present(cloud_event["id"])
  end

  defp reply_address(%{} = data), do: data["reply_address"]

  defp first_content_kind([%{"type" => type} | _rest]) when is_binary(type), do: type
  defp first_content_kind([%{"kind" => kind} | _rest]) when is_binary(kind), do: kind
  defp first_content_kind(_content), do: "unknown"

  defp primary_text(content) when is_list(content) do
    content
    |> Enum.flat_map(&content_text/1)
    |> Enum.join("\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp primary_text(_content), do: nil

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]

  defp content_text(%{"kind" => "text", "body" => %{"text" => text}}) when is_binary(text),
    do: [text]

  defp content_text(%{"text" => text}) when is_binary(text), do: [text]
  defp content_text(_block), do: []

  defp mentions(%{"routing_facts" => %{"mentions" => mentions}}) when is_list(mentions),
    do: mentions

  defp mentions(_data), do: []

  defp updated_at(type, time)
       when type in ["bullx.message.edited", "bullx.message.recalled", "bullx.message.deleted"],
       do: parse_time(time)

  defp updated_at(_type, _time), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _error -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp first_present(nil, next), do: next
  defp first_present("", next), do: next
  defp first_present(value, _next), do: value

  defp unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp maybe_stringify_map(nil), do: nil

  defp maybe_stringify_map(%{} = value) do
    case BullX.JSON.stringify_keys(value) do
      {:ok, normalized} -> normalized
      :error -> value
    end
  end

  defp maybe_stringify_map(_value), do: nil

  defp map_value(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_value(_value, _key), do: nil

  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(nil), do: ""
  defp string_value(value), do: to_string(value)

  defp string_or_nil(value) do
    case string_value(value) do
      "" -> nil
      string -> string
    end
  end

  defp safe_error(reason) when is_map(reason) do
    reason
    |> Map.take(["kind", "message", "code", :kind, :message, :code])
    |> case do
      empty when map_size(empty) == 0 -> %{"kind" => "delivery_failed"}
      safe -> maybe_stringify_map(safe)
    end
  end

  defp safe_error(reason) when is_atom(reason), do: %{"kind" => Atom.to_string(reason)}

  defp safe_error(reason), do: %{"kind" => "delivery_failed", "message" => inspect(reason)}

  defp reject_nil_values(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
