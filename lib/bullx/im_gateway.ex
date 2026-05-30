defmodule BullX.IMGateway do
  @moduledoc """
  IM boundary for normalized provider messages.

  IMGateway validates normalized IM events, emits CloudEvents mail to
  `BullX.MailBox`, and mirrors message facts into `im_rooms`/`im_messages` as
  best-effort long-term-memory input. Mail routing does not depend on those
  mirror rows.
  """

  alias BullX.IMGateway.{ChannelAdapter, Message, Room}
  alias BullX.Principals
  alias BullX.Principals.{ExternalIdentity, Principal}
  alias BullX.Repo

  import Ecto.Query, only: [from: 2]

  @inbound_dedupe_ttl_seconds 90_000
  @terminal_lifecycle_ttl_seconds @inbound_dedupe_ttl_seconds

  @im_event_types [
    "bullx.message.received",
    "bullx.command.invoked",
    "bullx.action.submitted",
    "bullx.message.edited",
    "bullx.message.recalled",
    "bullx.message.deleted"
  ]

  @addressed_attention_reasons ~w(dm mention free_response command reply_to_bot application_command mention_text batch_addressed)
  @terminal_lifecycle_event_types ["bullx.message.recalled", "bullx.message.deleted"]

  # Coalesce window/char-limit for IM mail batching. Defaults match production
  # behavior (6s debounce window, 8000 char early-flush). Overridable at runtime
  # via `config :bullx, :im_gateway, coalesce: [window_ms: ..., max_chars: ...]`
  # so integration tests can shrink the window for deterministic batching.
  @default_coalesce_window_ms 6_000
  @default_coalesce_max_chars 8_000

  @spec accept_message_event(map(), keyword()) :: {:ok, term()} | :ignore | {:error, term()}
  def accept_message_event(message_event, opts \\ [])
      when is_map(message_event) and is_list(opts) do
    case im_message_event?(message_event) do
      true ->
        with :ok <- reject_processed_inbound_event(message_event) do
          message_event
          |> accept_im_message_event(opts)
          |> mark_processed_inbound_event(message_event)
        end

      false ->
        {:error, {:unsupported_im_message_event_type, message_event["type"]}}
    end
  end

  @spec send_message(map(), keyword()) ::
          {:ok, %{message: Message.t() | nil, delivery: map()}}
          | {:error, %{message: Message.t() | nil, reason: term()}}
          | {:error, term()}
  def send_message(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    deliver_outbound(attrs, opts)
  end

  defp accept_im_message_event(message_event, opts) do
    with {:ok, actor} <- ensure_human_actor(message_event),
         :ok <- put_terminal_lifecycle_tombstone(message_event) do
      case route_im_mail(message_event, actor) do
        :route ->
          with {:ok, result} <- BullX.MailBox.route(mail_for_event(message_event, actor), opts) do
            {:ok, %{message: persist_inbound_mirror(message_event, actor), mailbox: result}}
          end

        {:blackhole, reason} ->
          {:ok, %{message: persist_inbound_mirror(message_event, actor), mailbox: reason}}

        {:skip, :skipped_terminal_lifecycle_message = reason} ->
          {:ok, %{message: nil, mailbox: reason}}

        {:skip, reason} ->
          {:ok, %{message: persist_inbound_mirror(message_event, actor), mailbox: reason}}
      end
    end
  end

  defp upsert_room(attrs) do
    %Room{}
    |> Room.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:kind, :title, :parent_room_id, :metadata, :updated_at]},
      conflict_target: [:provider, :provider_realm_id, :provider_room_id],
      returning: true
    )
  end

  defp insert_or_update_message(%Room{} = room, attrs) do
    attrs = Map.put(attrs, :room_id, room.id)

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert(
      on_conflict: message_conflict_update(),
      conflict_target: [:room_id, :provider_message_id],
      returning: true
    )
  end

  defp message_conflict_update do
    from message in Message,
      update: [
        set: [
          lifecycle_state:
            fragment(
              "CASE WHEN ? IN ('recalled', 'deleted') AND EXCLUDED.lifecycle_state NOT IN ('recalled', 'deleted') THEN ? ELSE EXCLUDED.lifecycle_state END",
              message.lifecycle_state,
              message.lifecycle_state
            ),
          actor_kind: fragment("EXCLUDED.actor_kind"),
          actor_provider_id: fragment("EXCLUDED.actor_provider_id"),
          actor: fragment("EXCLUDED.actor"),
          message_kind: fragment("EXCLUDED.message_kind"),
          text: fragment("EXCLUDED.text"),
          content: fragment("EXCLUDED.content"),
          attachments: fragment("EXCLUDED.attachments"),
          mentions: fragment("EXCLUDED.mentions"),
          provider_created_at: fragment("EXCLUDED.provider_created_at"),
          provider_updated_at: fragment("EXCLUDED.provider_updated_at"),
          observed_at: fragment("EXCLUDED.observed_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
  end

  defp persist_inbound_mirror(%{"type" => type}, _actor)
       when type in ["bullx.command.invoked", "bullx.action.submitted"],
       do: nil

  defp persist_inbound_mirror(message_event, actor) do
    with {:ok, room} <- safe_mirror(fn -> upsert_room(room_attrs(message_event)) end),
         {:ok, message} <-
           safe_mirror(fn ->
             insert_or_update_message(room, message_attrs(message_event, actor))
           end) do
      message
    else
      {:error, _reason} -> nil
    end
  end

  defp safe_mirror(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp reject_processed_inbound_event(%{"id" => id} = event) when is_binary(id) and id != "" do
    case BullX.Cache.get(inbound_dedupe_key(event)) do
      {:ok, _value} -> :ignore
      {:error, _reason} -> :ok
    end
  end

  defp reject_processed_inbound_event(_event), do: :ok

  defp mark_processed_inbound_event({:ok, _result} = result, event) do
    put_processed_inbound_event(event)
    result
  end

  defp mark_processed_inbound_event(result, _event), do: result

  defp put_processed_inbound_event(%{"id" => id} = event) when is_binary(id) and id != "" do
    _result = BullX.Cache.put(inbound_dedupe_key(event), "1", @inbound_dedupe_ttl_seconds)
    :ok
  end

  defp put_processed_inbound_event(_event), do: :ok

  defp inbound_dedupe_key(event) do
    source = string_value(event["source"] || "unknown")
    "im_gateway:inbound:#{source}:#{event["id"]}"
  end

  defp put_terminal_lifecycle_tombstone(%{"type" => type, "data" => %{} = data})
       when type in @terminal_lifecycle_event_types do
    case terminal_lifecycle_tombstone_key(data) do
      {:ok, key} ->
        _result = BullX.Cache.put(key, type, @terminal_lifecycle_ttl_seconds)
        :ok

      :error ->
        :ok
    end
  end

  defp put_terminal_lifecycle_tombstone(_event), do: :ok

  defp terminal_lifecycle_tombstone?(%{} = data) do
    case terminal_lifecycle_tombstone_key(data) do
      {:ok, key} ->
        case BullX.Cache.get(key) do
          {:ok, _value} -> true
          {:error, _reason} -> false
        end

      :error ->
        false
    end
  end

  defp terminal_lifecycle_tombstone?(_data), do: false

  defp terminal_lifecycle_tombstone_key(%{} = data) do
    channel = data["channel"] || %{}
    scope = data["scope"] || %{}

    case string_or_nil(provider_message_id(data, %{})) do
      nil ->
        :error

      message_id ->
        parts = [
          provider(channel),
          provider_realm_id(data),
          provider_room_id(scope, data),
          message_id
        ]

        {:ok, "im_gateway:terminal_lifecycle:v1:" <> Enum.map_join(parts, ":", &cache_key_part/1)}
    end
  end

  defp cache_key_part(value), do: Base.url_encode64(value, padding: false)

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
      provider_realm_id: provider_realm_id(data),
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
      lifecycle_state: message_lifecycle_state(cloud_event["type"]),
      provider_message_id: provider_message_id(data, cloud_event),
      actor_kind: actor_kind(actor),
      actor_provider_id: actor["external_account_id"],
      actor: im_actor_snapshot(actor),
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
      provider_created_at: parse_time(cloud_event["time"]),
      provider_updated_at: updated_at(cloud_event["type"], cloud_event["time"]),
      observed_at: now
    }
  end

  defp mail_for_event(cloud_event, actor) do
    data = cloud_event["data"] || %{}
    mail_type = cloud_event["type"] || "bullx.message.received"
    channel = data["channel"] || %{}
    queue_key = queue_key(data)
    provider_message_id = provider_message_id(data, cloud_event)
    content = data["content"] || []

    %{
      "specversion" => "1.0",
      "id" => "#{cloud_event["source"]}:#{cloud_event["id"]}:#{mail_type}",
      "source" => "bullx://im-gateway/#{provider(channel)}/#{source_id(channel)}",
      "type" => mail_type,
      "subject" => queue_key,
      "time" => cloud_event["time"] || DateTime.to_iso8601(utc_now()),
      "datacontenttype" => "application/json",
      "data" =>
        %{
          "queue_key" => queue_key,
          "source_fact" =>
            %{
              "gateway" => "im_gateway",
              "kind" => "im_message",
              "id" => provider_message_id,
              "room_key" => queue_key,
              "provider_message_id" => provider_message_id,
              "provider_occurrence_id" => cloud_event["id"],
              "event_type" => mail_type,
              "revision" => source_revision(mail_type)
            }
            |> reject_nil_values(),
          "provider" => provider(channel),
          "source_id" => source_id(channel),
          "actor_principal_uid" => get_in(actor, ["principal", "uid"]),
          "message_kind" => first_content_kind(content),
          "text_preview" => primary_text(content),
          "attention" => Atom.to_string(event_attention(mail_type, data)),
          "coalesce" => coalesce_config(),
          "conversation_context" => conversation_context(data, actor),
          "content" => content,
          "channel" => channel,
          "scope" => data["scope"] || %{},
          "actor" => actor,
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
      provider_realm_id: outbound_provider_realm_id(reply_address, attrs),
      provider_room_id: outbound_provider_room_id(reply_address, attrs),
      kind: :unknown,
      metadata: %{}
    }
  end

  defp outbound_provider_room_id(reply_address, attrs) do
    scope_id =
      string_value(
        reply_address["scope_id"] || reply_address[:scope_id] ||
          map_value(attrs, :provider_room_id) || "unknown"
      )

    case string_or_nil(reply_address["thread_id"] || reply_address[:thread_id]) do
      nil -> scope_id
      thread_id -> "#{scope_id}#thread:#{thread_id}"
    end
  end

  defp outbound_provider_realm_id(reply_address, attrs) do
    first_string([
      reply_address["provider_realm_id"],
      reply_address[:provider_realm_id],
      reply_address["realm_id"],
      reply_address[:realm_id],
      reply_address["tenant_key"],
      reply_address[:tenant_key],
      reply_address["guild_id"],
      reply_address[:guild_id],
      map_value(attrs, :provider_realm_id),
      map_value(attrs, :realm_id)
    ])
  end

  defp outbound_message_attrs(attrs, _opts) do
    now = utc_now()
    content = outbound_content(attrs)

    %{
      lifecycle_state: :active,
      provider_message_id: nil,
      actor_kind: string_value(map_value(attrs, :actor_kind) || "bot"),
      actor_provider_id: map_value(attrs, :actor_provider_id),
      actor: outbound_actor_snapshot(attrs),
      message_kind: string_value(map_value(attrs, :message_kind) || first_content_kind(content)),
      text: map_value(attrs, :text) || primary_text(content),
      content: %{"blocks" => content},
      attachments: map_value(attrs, :attachments) || [],
      mentions: map_value(attrs, :mentions) || [],
      observed_at: now
    }
  end

  defp outbound_actor_snapshot(attrs) do
    attrs
    |> map_value(:actor)
    |> maybe_stringify_map()
    |> case do
      %{} = actor -> im_actor_snapshot(actor)
      nil -> %{"kind" => string_value(map_value(attrs, :actor_kind) || "bot")}
    end
  end

  defp deliver_outbound(attrs, opts) do
    reply_address = maybe_stringify_map(map_value(attrs, :reply_address)) || %{}
    occurrence_id = outbound_occurrence_id(attrs)
    attrs = Map.put(attrs, :provider_occurrence_id, occurrence_id)
    outbound = outbound_delivery_payload(attrs, occurrence_id)

    case ChannelAdapter.deliver(reply_address, outbound, opts) do
      {:ok, delivery} ->
        message = persist_sent_outbound_mirror(attrs, delivery)
        {:ok, %{message: message, delivery: delivery}}

      {:error, reason} ->
        {:error, %{message: nil, reason: reason}}
    end
  end

  defp outbound_delivery_payload(attrs, occurrence_id) do
    %{
      "id" => occurrence_id,
      "op" => string_value(map_value(attrs, :op) || "send"),
      "content" => outbound_content(attrs)
    }
    |> put_optional("target_external_id", map_value(attrs, :target_external_id))
  end

  defp persist_sent_outbound_mirror(attrs, delivery) when is_map(delivery) do
    persist_outbound_mirror(attrs, %{
      lifecycle_state: outbound_lifecycle_state(delivery),
      provider_message_id: outbound_provider_message_id(attrs, delivery)
    })
  end

  defp persist_outbound_mirror(attrs, extra_attrs) do
    case string_or_nil(extra_attrs[:provider_message_id]) do
      nil ->
        nil

      _message_id ->
        safe_mirror(fn ->
          with {:ok, room} <- upsert_room(outbound_room_attrs(attrs)),
               {:ok, message} <-
                 insert_or_update_message(
                   room,
                   attrs
                   |> outbound_message_attrs([])
                   |> Map.merge(extra_attrs)
                 ) do
            {:ok, message}
          end
        end)
        |> case do
          {:ok, message} -> message
          {:error, _reason} -> nil
        end
    end
  end

  defp outbound_occurrence_id(attrs),
    do:
      string_or_nil(map_value(attrs, :provider_occurrence_id) || map_value(attrs, :id)) ||
        BullX.Ext.gen_uuid_v7()

  defp outbound_lifecycle_state(%{"status" => "recalled"}), do: :recalled
  defp outbound_lifecycle_state(_delivery), do: :active

  defp outbound_provider_message_id(attrs, %{"status" => "recalled"} = delivery),
    do: primary_external_id(delivery) || string_or_nil(map_value(attrs, :target_external_id))

  defp outbound_provider_message_id(_attrs, delivery), do: primary_external_id(delivery)

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

  defp coalesce_config do
    coalesce = Keyword.get(Application.get_env(:bullx, :im_gateway, []), :coalesce, [])

    %{
      "window_ms" => Keyword.get(coalesce, :window_ms, @default_coalesce_window_ms),
      "max_chars" => Keyword.get(coalesce, :max_chars, @default_coalesce_max_chars)
    }
  end

  defp conversation_context(data, actor) do
    channel = data["channel"] || %{}
    scope = data["scope"] || %{}
    actor = actor || data["actor"] || %{}

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
        "principal_uid" => get_in(actor, ["principal", "uid"]),
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
      "profile" => channel_actor_profile(actor),
      "metadata" => %{}
    }
  end

  defp channel_actor_profile(actor) do
    profile =
      case maybe_stringify_map(actor["profile"] || actor[:profile]) do
        %{} = normalized -> normalized
        nil -> %{}
      end

    profile
    |> put_optional("uid", actor["uid"] || actor[:uid] || actor["user_id"] || actor[:user_id])
    |> put_optional("display_name", actor["display_name"] || actor["display"])
    |> put_optional("avatar_url", actor["avatar_url"])
    |> put_optional("email", actor["email"])
    |> put_optional("phone", actor["phone"])
    |> reject_nil_values()
  end

  defp route_im_mail(%{"type" => "bullx.message.received", "data" => data}, actor) do
    attention = event_attention("bullx.message.received", data)

    cond do
      attention == :addressed and human_actor?(actor) and
          actor["external_identity_verified"] != true ->
        {:skip, :skipped_unverified_actor}

      terminal_lifecycle_tombstone?(data) ->
        {:skip, :skipped_terminal_lifecycle_message}

      attention == :ambient and group_message_mode(data) not in ["observe_all", "engage_all"] ->
        {:blackhole, :blackholed_unaddressed_group_message}

      true ->
        :route
    end
  end

  defp route_im_mail(%{"type" => "bullx.action.submitted"}, _actor),
    do: {:skip, :skipped_non_message_input}

  defp route_im_mail(%{"type" => type, "data" => _data}, _actor)
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

  defp im_message_event?(%{"type" => type}) when type in @im_event_types, do: true
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

  defp im_actor_snapshot(%{} = actor) do
    actor
    |> maybe_stringify_map()
    |> Map.drop(["principal", "external_identity_id", "external_identity_verified"])
    |> reject_nil_values()
  end

  defp provider(channel), do: string_value(channel["adapter"] || channel[:adapter] || "unknown")
  defp source_id(channel), do: string_value(channel["id"] || channel[:id] || "default")

  defp trusted_realm_by_default?(%{"trusted_realm_by_default" => value}) when is_boolean(value),
    do: value

  defp trusted_realm_by_default?(%{trusted_realm_by_default: value}) when is_boolean(value),
    do: value

  defp trusted_realm_by_default?(_channel), do: false

  defp provider_room_id(scope, data) do
    scope_id =
      string_value(
        scope["id"] ||
          scope[:id] ||
          get_in(data, ["reply_address", "scope_id"]) ||
          get_in(data, [:reply_address, :scope_id]) ||
          "unknown"
      )

    case string_or_nil(scope["thread_id"] || scope[:thread_id]) do
      nil -> scope_id
      thread_id -> "#{scope_id}#thread:#{thread_id}"
    end
  end

  defp provider_realm_id(%{} = data) do
    routing_facts = data["routing_facts"] || %{}
    raw_ref = data["raw_ref"] || %{}
    scope = data["scope"] || %{}

    first_string([
      scope["provider_realm_id"],
      scope["realm_id"],
      routing_facts["provider_realm_id"],
      routing_facts["realm_id"],
      routing_facts["tenant_key"],
      raw_ref["tenant_key"],
      routing_facts["guild_id"],
      raw_ref["guild_id"],
      routing_facts["workspace_id"],
      raw_ref["workspace_id"]
    ])
  end

  defp room_kind(%{"kind" => "dm"}, _facts), do: :direct
  defp room_kind(%{"kind" => "direct"}, _facts), do: :direct
  defp room_kind(%{"kind" => "group"}, _facts), do: :group
  defp room_kind(%{"kind" => "channel"}, _facts), do: :group
  defp room_kind(_channel, %{"chat_type" => "p2p"}), do: :direct
  defp room_kind(_channel, %{"chat_type" => "private"}), do: :direct
  defp room_kind(_channel, _facts), do: :unknown

  defp queue_key(%{} = data) do
    channel = data["channel"] || %{}
    scope = data["scope"] || %{}

    "im://#{provider(channel)}/#{source_id(channel)}/#{provider_room_id(scope, data)}"
  end

  defp message_lifecycle_state("bullx.message.edited"), do: :edited
  defp message_lifecycle_state("bullx.message.recalled"), do: :recalled
  defp message_lifecycle_state("bullx.message.deleted"), do: :deleted
  defp message_lifecycle_state(_type), do: :active

  defp addressed_received?(%{"routing_facts" => %{} = facts}) do
    reason = string_value(facts["attention_reason"])

    cond do
      reason in @addressed_attention_reasons -> true
      reason == "unaddressed" -> false
      true -> true
    end
  end

  defp addressed_received?(_data), do: true

  defp event_attention("bullx.command.invoked", _data), do: :command

  defp event_attention(type, _data)
       when type in ["bullx.message.edited", "bullx.message.recalled", "bullx.message.deleted"],
       do: :lifecycle

  defp event_attention("bullx.message.received", %{} = data) do
    case addressed_received?(data) do
      true -> :addressed
      false -> :ambient
    end
  end

  defp event_attention(_type, _data), do: :system

  defp group_message_mode(%{"routing_facts" => %{} = facts}) do
    string_value(facts["group_message_mode"])
  end

  defp group_message_mode(_data), do: ""

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

  defp first_string(values) when is_list(values) do
    Enum.find_value(values, &string_or_nil/1) || ""
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
  defp string_value(nil), do: ""
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value), do: to_string(value)

  defp string_or_nil(value) do
    case string_value(value) do
      "" -> nil
      string -> string
    end
  end

  defp reject_nil_values(map),
    do: Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
