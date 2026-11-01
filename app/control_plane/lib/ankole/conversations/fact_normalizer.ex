defmodule Ankole.Conversations.FactNormalizer do
  import Ankole.Attrs,
    only: [
      collect_results: 1,
      normalize_provider_lifecycle_kind: 1,
      structured_mention?: 2,
      truthy?: 1
    ]

  @moduledoc false

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Signals.Sanitizer
  alias Ankole.Signals.Binding

  @type channel :: %{
          optional(:kind) =>
            :im_dm | :im_group | :webhook_endpoint | :issue | :alert_stream | String.t(),
          optional(:reply_mode) => :channel | :entry | :none | String.t(),
          optional(:name) => String.t(),
          optional(:visibility) => String.t(),
          optional(:metadata) => map(),
          optional(:raw_payload) => map()
        }
  @type entry_input :: %{
          required(:source_event_id) => String.t(),
          required(:provider_conversation_id) => String.t(),
          required(:provider_message_id) => String.t(),
          optional(:reply_to_provider_message_id) => String.t() | nil,
          optional(:provider_thread_id) => String.t() | nil,
          optional(:channel) => channel(),
          optional(:text) => String.t() | nil,
          optional(:formatted_content) => map(),
          optional(:attachments) => [map()],
          optional(:links) => [map()],
          optional(:author) => map(),
          optional(:mentions) => [map()],
          optional(:metadata) => map(),
          optional(:raw_payload) => map(),
          optional(:provider_time) => DateTime.t() | nil,
          optional(:explicit) => boolean(),
          optional(:mirror_only) => boolean(),
          optional(:signal_type) => String.t() | nil,
          optional(:structured_mention_prefixes) => [String.t()]
        }
  @type removal_input :: %{
          required(:source_event_id) => String.t(),
          required(:provider_conversation_id) => String.t(),
          required(:provider_message_id) => String.t(),
          optional(:provider_thread_id) => String.t() | nil,
          optional(:channel) => channel(),
          optional(:metadata) => map(),
          optional(:raw_payload) => map(),
          optional(:provider_time) => DateTime.t() | nil,
          optional(:provider_lifecycle_kind) => atom() | String.t()
        }
  @type reaction_input :: %{
          required(:provider_conversation_id) => String.t(),
          required(:provider_message_id) => String.t(),
          required(:reaction_key) => String.t(),
          required(:actor_key) => String.t(),
          optional(:source_event_id) => String.t(),
          optional(:action) => :add | :remove | String.t(),
          optional(:raw_reaction_key) => String.t(),
          optional(:provider_time) => DateTime.t() | nil
        }
  @type action_input :: %{
          required(:source_event_id) => String.t(),
          required(:action_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:provider_conversation_id) => String.t(),
          optional(:provider_message_id) => String.t(),
          optional(:provider_thread_id) => String.t() | nil,
          optional(:channel) => channel(),
          optional(:action) => map(),
          optional(:raw_payload) => map(),
          optional(:signal_type) => String.t()
        }

  def entry(%Binding{} = binding, input, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, source_event_id} <- required_attr_text(input, :source_event_id),
         {:ok, provider_conversation_id} <- required_attr_text(input, :provider_conversation_id),
         {:ok, provider_message_id} <- required_attr_text(input, :provider_message_id),
         {:ok, attachments} <- normalize_attachments(input),
         {:ok, links} <- normalize_json_list(attr_list(input, :links), :links),
         {:ok, author} <- normalize_json_map(attr_map(input, :author, %{}), :author),
         :ok <- validate_provider_author(author),
         {:ok, mentions} <- normalize_json_list(attr_list(input, :mentions), :mentions),
         {:ok, formatted_content} <-
           normalize_json_map(attr_map(input, :formatted_content, %{}), :formatted_content),
         {:ok, metadata} <-
           normalize_json_map(attr_map(input, :metadata, %{}), :metadata),
         {:ok, raw_payload} <- normalize_raw_payload(input),
         {:ok, channel_metadata} <- normalize_channel_metadata(input),
         {:ok, channel_raw_payload} <- normalize_channel_raw_payload(input) do
      channel = attr_map(input, :channel, %{})

      channel_kind =
        normalize_channel_kind(Map.get(channel, :kind))

      channel_metadata =
        put_dm_peer_principal(channel_metadata, channel_kind, author, binding.agent_uid)

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_id: binding.id,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         provider_conversation_id: provider_conversation_id,
         provider_message_id: provider_message_id,
         reply_to_provider_message_id: optional_attr_text(input, :reply_to_provider_message_id),
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         channel_kind: channel_kind,
         reply_mode: normalize_reply_mode(Map.get(channel, :reply_mode)),
         channel_name: optional_attr_text(channel, :name),
         channel_visibility: optional_attr_text(channel, :visibility),
         channel_metadata: channel_metadata,
         channel_raw_payload: channel_raw_payload,
         text: optional_attr_text(input, :text),
         formatted_content: formatted_content,
         attachments: attachments,
         links: links,
         author: author,
         mentions: mentions,
         metadata: metadata,
         raw_payload: raw_payload,
         provider_time: attr_datetime(input, :provider_time),
         explicit?:
           truthy?(Map.get(input, :explicit)) ||
             structured_agent_mention?(mentions, binding.agent_uid),
         mirror_only?: truthy?(Map.get(input, :mirror_only)),
         signal_type: optional_attr_text(input, :signal_type),
         command_prefixes: attr_list(input, :structured_mention_prefixes),
         sender_key: sender_key(author),
         gateway_time: now
       }}
    end
  end

  def lifecycle(%Binding{} = binding, input, provider_lifecycle_kind, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, source_event_id} <- required_attr_text(input, :source_event_id),
         {:ok, provider_conversation_id} <- required_attr_text(input, :provider_conversation_id),
         {:ok, provider_message_id} <- required_attr_text(input, :provider_message_id),
         {:ok, metadata} <-
           normalize_json_map(attr_map(input, :metadata, %{}), :metadata),
         {:ok, raw_payload} <- normalize_raw_payload(input),
         {:ok, channel_metadata} <- normalize_channel_metadata(input),
         {:ok, channel_raw_payload} <- normalize_channel_raw_payload(input) do
      channel = attr_map(input, :channel, %{})

      provider_lifecycle_kind =
        provider_lifecycle_kind ||
          metadata
          |> Map.get("provider_lifecycle_kind")
          |> normalize_provider_lifecycle_kind()

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_id: binding.id,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         provider_conversation_id: provider_conversation_id,
         provider_message_id: provider_message_id,
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         channel_kind: normalize_channel_kind(Map.get(channel, :kind)),
         reply_mode: normalize_reply_mode(Map.get(channel, :reply_mode)),
         channel_name: optional_attr_text(channel, :name),
         channel_visibility: optional_attr_text(channel, :visibility),
         channel_metadata: channel_metadata,
         channel_raw_payload: channel_raw_payload,
         metadata: metadata,
         raw_payload: raw_payload,
         provider_time: attr_datetime(input, :provider_time),
         lifecycle_kind: :removed,
         provider_lifecycle_kind: provider_lifecycle_kind,
         gateway_time: now
       }}
    end
  end

  def reaction(%Binding{} = binding, input, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, provider_conversation_id} <- required_attr_text(input, :provider_conversation_id),
         {:ok, provider_message_id} <- required_attr_text(input, :provider_message_id),
         {:ok, reaction_key} <- required_attr_text(input, :reaction_key),
         {:ok, actor_key} <- required_attr_text(input, :actor_key) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_id: binding.id,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: optional_attr_text(input, :source_event_id),
         provider_conversation_id: provider_conversation_id,
         provider_message_id: provider_message_id,
         reaction_key: reaction_key,
         actor_key: actor_key,
         action: normalize_reaction_action(Map.get(input, :action)),
         raw_reaction_key: optional_attr_text(input, :raw_reaction_key) || reaction_key,
         provider_time: attr_datetime(input, :provider_time),
         gateway_time: now
       }}
    end
  end

  def action(%Binding{} = binding, input, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, source_event_id} <- required_attr_text(input, :source_event_id),
         {:ok, session_id} <- action_session_id(input),
         {:ok, action_id} <- required_attr_text(input, :action_id),
         {:ok, action} <- normalize_json_map(attr_map(input, :action, %{}), :action),
         {:ok, raw_payload} <- normalize_raw_payload(input),
         {:ok, channel_metadata} <- normalize_channel_metadata(input),
         {:ok, channel_raw_payload} <- normalize_channel_raw_payload(input) do
      provider_conversation_id = optional_attr_text(input, :provider_conversation_id)
      channel = attr_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_id: binding.id,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         action_id: action_id,
         session_id: session_id,
         provider_conversation_id: provider_conversation_id,
         provider_message_id: optional_attr_text(input, :provider_message_id),
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         sender_key: Map.get(action, "operator_principal_uid"),
         channel_kind: normalize_channel_kind(Map.get(channel, :kind)),
         reply_mode: normalize_reply_mode(Map.get(channel, :reply_mode)),
         channel_name: optional_attr_text(channel, :name),
         channel_visibility: optional_attr_text(channel, :visibility),
         channel_metadata: channel_metadata,
         channel_raw_payload: channel_raw_payload,
         signal_type: optional_attr_text(input, :signal_type) || "signal.action.invoked",
         action: action,
         raw_payload: raw_payload,
         gateway_time: now
       }}
    end
  end

  # The routing decision: given an accepted entry fact, what should it become?
  # Order matters — these are tried top to bottom and the first match wins:
  #   1. mirror_only: caller asked to only record, never wake the agent.
  #   2. a recognized /slash command in addressed text → command.* Signal.
  #   3. an adapter-supplied explicit signal_type (non-IM sources).
  #   4. a DM, structured group mention, or reply resolved to the current agent
  #      → a normal addressed message.
  #   5. an unaddressed group message → defer to the binding's group policy.

  defp action_session_id(input) do
    case optional_attr_text(input, :session_id) ||
           optional_attr_text(input, :provider_conversation_id) do
      nil ->
        {:error, :missing_session_id}

      _session_or_conversation ->
        {:ok, optional_attr_text(input, :session_id)}
    end
  end

  # A DM's peer is a durable routing fact, not a provider-specific payload
  # detail. Persist the normalized Ankole principal on the channel mirror so a
  # later system event in the same channel can declare the same conversation
  # origin without reinterpreting an old message body.
  defp put_dm_peer_principal(metadata, :im_dm, author, agent_uid) do
    case Ankole.Attrs.optional_text(Map.get(author, "principal_uid")) do
      principal_uid when is_binary(principal_uid) ->
        principal_uid = Ankole.PrincipalKey.canonicalize(principal_uid)

        if principal_uid == agent_uid do
          metadata
        else
          Map.put(metadata, "dm_peer_principal_uid", principal_uid)
        end

      nil ->
        metadata
    end
  end

  defp put_dm_peer_principal(metadata, _channel_kind, _author, _agent_uid), do: metadata

  defp structured_agent_mention?(mentions, agent_uid) do
    Enum.any?(mentions, fn mention ->
      structured_mention?(mention, agent_uid)
    end)
  end

  defp sender_key(author) do
    Ankole.Attrs.optional_text(Map.get(author, "platform_subject")) ||
      Ankole.Attrs.optional_text(Map.get(author, "external_id")) ||
      Ankole.Attrs.optional_text(Map.get(author, "id"))
  end

  defp validate_provider_author(author) do
    case Enum.find(
           ["principal_uid", "agent_uid", "human_access_version"],
           &Map.has_key?(author, &1)
         ) do
      nil -> :ok
      key -> {:error, {:invalid_ingress_author_authority, key}}
    end
  end

  @doc false
  @spec put_author_principal(struct(), String.t()) :: struct()
  def put_author_principal(fact, principal_uid) do
    principal_uid = Ankole.PrincipalKey.canonicalize(principal_uid)
    author = Map.put(fact.author || %{}, "principal_uid", principal_uid)

    channel_metadata =
      put_dm_peer_principal(
        fact.channel_metadata || %{},
        fact.channel_kind,
        author,
        fact.agent_uid
      )

    %{fact | author: author, channel_metadata: channel_metadata, sender_key: principal_uid}
  end

  defp normalize_attachments(input) do
    input
    |> attr_list(:attachments)
    |> Enum.map(&normalize_attachment/1)
    |> collect_results()
  end

  defp validate_attr_keys(map) when is_map(map) do
    case Enum.find(Map.keys(map), &(not is_atom(&1))) do
      nil ->
        case Enum.find(
               [
                 :sender_key,
                 :principal_uid,
                 :agent_uid,
                 :human_access_version,
                 :channel_kind,
                 :reply_mode,
                 :channel_name,
                 :channel_visibility,
                 :raw
               ],
               &Map.has_key?(map, &1)
             ) do
          nil -> validate_channel_attr_keys(Map.get(map, :channel))
          key -> {:error, {:invalid_ingress_attr_key, key}}
        end

      key ->
        {:error, {:invalid_ingress_attr_key, key}}
    end
  end

  defp validate_attr_keys(_value), do: {:error, :invalid_ingress_attrs}

  defp validate_channel_attr_keys(nil), do: :ok

  defp validate_channel_attr_keys(channel) when is_map(channel) do
    case Enum.find(Map.keys(channel), &(not is_atom(&1))) do
      nil ->
        if Map.has_key?(channel, :raw),
          do: {:error, {:invalid_ingress_channel_attr_key, :raw}},
          else: :ok

      key ->
        {:error, {:invalid_ingress_channel_attr_key, key}}
    end
  end

  defp validate_channel_attr_keys(_value), do: {:error, :invalid_ingress_channel_attrs}

  defp required_attr_text(map, key) do
    case optional_attr_text(map, key) do
      nil -> {:error, {:missing_required_text, key}}
      value -> {:ok, value}
    end
  end

  defp optional_attr_text(map, key) when is_map(map) and is_atom(key) do
    Ankole.Attrs.optional_text(Map.get(map, key))
  end

  defp optional_attr_text(_map, _key), do: nil

  defp attr_map(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp attr_map(_map, _key, default), do: default

  defp attr_list(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      nil -> []
      value -> [value]
    end
  end

  defp attr_list(_map, _key), do: []

  defp attr_datetime(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp attr_datetime(_map, _key), do: nil

  defp normalize_raw_payload(input) do
    normalize_json_map(attr_map(input, :raw_payload, %{}), :raw_payload)
  end

  defp normalize_channel_metadata(input) do
    input
    |> attr_map(:channel, %{})
    |> attr_map(:metadata, %{})
    |> normalize_json_map(:channel_metadata)
  end

  defp normalize_channel_raw_payload(input) do
    channel = attr_map(input, :channel, %{})

    normalize_json_map(
      attr_map(channel, :raw_payload, %{}),
      :channel_raw_payload
    )
  end

  defp normalize_json_map(value, field) do
    case JSONPayload.normalize_map(value, allow_datetime: true) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_ingress_json, field, reason}}
    end
  end

  defp normalize_json_list(value, field) do
    case JSONPayload.normalize_list(value, allow_datetime: true) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_ingress_json, field, reason}}
    end
  end

  defp normalize_attachment(%{} = attachment) do
    case JSONPayload.normalize_map(attachment, allow_datetime: true) do
      {:ok, normalized} ->
        normalized = sanitize_attachment_names(normalized)

        case durable_attachment?(normalized) do
          true -> {:ok, normalized}
          false -> {:error, {:attachment_not_materialized, Sanitizer.transport(normalized)}}
        end

      {:error, _reason} ->
        {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}
    end
  end

  defp normalize_attachment(attachment),
    do: {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}

  defp sanitize_attachment_names(attachment) when is_map(attachment) do
    attachment =
      Enum.reduce(["name", "filename", "file_name", "title"], attachment, fn key, acc ->
        case Map.get(acc, key) do
          value when is_binary(value) ->
            cond do
              value == "" ->
                acc

              String.trim(value) == "" and not Ankole.Files.Path.contains_control_or_bidi?(value) ->
                Map.put(acc, key, "")

              true ->
                Map.put(acc, key, Ankole.Files.Path.file_name(value))
            end

          _ ->
            acc
        end
      end)

    case Map.get(attachment, "path") do
      value when is_binary(value) ->
        cond do
          value == "" ->
            attachment

          String.trim(value) == "" and not Ankole.Files.Path.contains_control_or_bidi?(value) ->
            Map.put(attachment, "path", "")

          true ->
            Map.put(attachment, "path", Ankole.Files.Path.sanitize_display_path(value))
        end

      _ ->
        attachment
    end
  end

  # An attachment is only accepted into durable state once it points at something
  # that will still resolve later: a provider, drive content, or storage
  # reference. A Home path can change and is not an attachment reference.
  # Raw in-memory or transient attachments are rejected (normalize_attachment/1),
  # so the mirror does not store a pointer that the Agent cannot fetch again.
  defp durable_attachment?(attachment) do
    Enum.any?(
      ["provider_ref", "provider_file_id", "provider_uri", "object_id", "storage_ref"],
      &present_text?(attachment, &1)
    )
  end

  defp present_text?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp normalize_channel_kind(value) when value in [:im_dm, "im_dm"], do: :im_dm

  defp normalize_channel_kind(value) when value in [:im_group, "im_group"], do: :im_group

  defp normalize_channel_kind(value) when value in [:webhook_endpoint, "webhook_endpoint"],
    do: :webhook_endpoint

  defp normalize_channel_kind(value) when value in [:issue, "issue"], do: :issue

  defp normalize_channel_kind(value) when value in [:alert_stream, "alert_stream"],
    do: :alert_stream

  defp normalize_channel_kind(_value), do: :unknown

  defp normalize_reaction_action(value) when value in [:remove, "remove", :deleted, "deleted"],
    do: :remove

  defp normalize_reaction_action(_value), do: :add

  defp normalize_reply_mode(value) when value in [:channel, "channel"], do: :channel

  defp normalize_reply_mode(value) when value in [:entry, "entry"], do: :entry

  defp normalize_reply_mode(_value), do: :none
end
