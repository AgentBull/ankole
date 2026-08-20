defmodule Ankole.SignalsGateway.FactNormalizer do
  @moduledoc false

  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Binding

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      normalize_channel_kind: 1,
      normalize_provider_lifecycle_kind: 1,
      normalize_reaction_action: 1,
      normalize_reply_mode: 1,
      normalize_uid: 1,
      signal_session_id: 1,
      structured_mention?: 2,
      truthy?: 1
    ]

  def entry(%Binding{} = binding, input, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, source_event_id} <- required_attr_text(input, :source_event_id),
         {:ok, signal_channel_id} <- required_attr_text(input, :signal_channel_id),
         {:ok, source_entry_id} <- required_attr_text(input, :source_entry_id),
         {:ok, attachments} <- normalize_attachments(input),
         {:ok, links} <- normalize_json_list(attr_list(input, :links), :links),
         {:ok, author} <- normalize_json_map(attr_map(input, :author, %{}), :author),
         {:ok, mentions} <- normalize_json_list(attr_list(input, :mentions), :mentions),
         {:ok, formatted_content} <-
           normalize_json_map(attr_map(input, :formatted_content, %{}), :formatted_content),
         {:ok, metadata} <-
           normalize_json_map(attr_map(input, :metadata, %{}), :metadata),
         {:ok, raw_payload} <- normalize_raw_payload(input),
         {:ok, channel_metadata} <- normalize_channel_metadata(input),
         {:ok, channel_raw_payload} <- normalize_channel_raw_payload(input) do
      channel = attr_map(input, :channel, %{})
      author = normalize_author_principal(binding, author)

      channel_kind =
        normalize_channel_kind(Map.get(channel, :kind) || Map.get(input, :channel_kind))

      channel_metadata =
        put_dm_peer_principal(channel_metadata, channel_kind, author, binding.agent_uid)

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         signal_channel_id: signal_channel_id,
         source_entry_id: source_entry_id,
         reply_to_source_entry_id: optional_attr_text(input, :reply_to_source_entry_id),
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         channel_kind: channel_kind,
         reply_mode:
           normalize_reply_mode(Map.get(channel, :reply_mode) || Map.get(input, :reply_mode)),
         channel_name: channel_name(input, channel),
         channel_visibility:
           optional_attr_text(channel, :visibility) ||
             optional_attr_text(input, :channel_visibility),
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
         actor_event_type: optional_attr_text(input, :actor_event_type),
         command_prefixes: attr_list(input, :structured_mention_prefixes),
         sender_key: sender_key(input, author),
         gateway_time: now
       }}
    end
  end

  def lifecycle(%Binding{} = binding, input, provider_lifecycle_kind, now) do
    with :ok <- validate_attr_keys(input),
         {:ok, source_event_id} <- required_attr_text(input, :source_event_id),
         {:ok, signal_channel_id} <- required_attr_text(input, :signal_channel_id),
         {:ok, source_entry_id} <- required_attr_text(input, :source_entry_id),
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
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         signal_channel_id: signal_channel_id,
         source_entry_id: source_entry_id,
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(Map.get(channel, :kind) || Map.get(input, :channel_kind)),
         reply_mode:
           normalize_reply_mode(Map.get(channel, :reply_mode) || Map.get(input, :reply_mode)),
         channel_name: channel_name(input, channel),
         channel_visibility:
           optional_attr_text(channel, :visibility) ||
             optional_attr_text(input, :channel_visibility),
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
         {:ok, signal_channel_id} <- required_attr_text(input, :signal_channel_id),
         {:ok, source_entry_id} <- required_attr_text(input, :source_entry_id),
         {:ok, reaction_key} <- required_attr_text(input, :reaction_key),
         {:ok, actor_key} <- required_attr_text(input, :actor_key) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: optional_attr_text(input, :source_event_id),
         signal_channel_id: signal_channel_id,
         source_entry_id: source_entry_id,
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
      signal_channel_id = optional_attr_text(input, :signal_channel_id)
      channel = attr_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         source_event_id: source_event_id,
         action_id: action_id,
         session_id: session_id,
         signal_channel_id: signal_channel_id,
         source_entry_id: optional_attr_text(input, :source_entry_id),
         provider_thread_id: optional_attr_text(input, :provider_thread_id),
         sender_key: nil,
         channel_kind:
           normalize_channel_kind(Map.get(channel, :kind) || Map.get(input, :channel_kind)),
         reply_mode:
           normalize_reply_mode(Map.get(channel, :reply_mode) || Map.get(input, :reply_mode)),
         channel_name: channel_name(input, channel),
         channel_visibility:
           optional_attr_text(channel, :visibility) ||
             optional_attr_text(input, :channel_visibility),
         channel_metadata: channel_metadata,
         channel_raw_payload: channel_raw_payload,
         actor_event_type:
           optional_attr_text(input, :actor_event_type) || "signal.action.invoked",
         action: action,
         raw_payload: raw_payload,
         gateway_time: now
       }}
    end
  end

  # The routing decision: given an accepted entry fact, what should it become?
  # Order matters — these are tried top to bottom and the first match wins:
  #   1. mirror_only: caller asked to only record, never wake the agent.
  #   2. a recognized /slash command in addressed text → command.* actor event.
  #   3. an adapter-supplied explicit actor_event_type (non-IM sources).
  #   4. a DM, structured group mention, or reply resolved to the current agent
  #      → a normal addressed message.
  #   5. an unaddressed group message → defer to the binding's group policy.

  defp action_session_id(input) do
    case optional_attr_text(input, :session_id) || optional_attr_text(input, :signal_channel_id) do
      nil ->
        {:error, :missing_session_id}

      session_or_channel ->
        {:ok, optional_attr_text(input, :session_id) || signal_session_id(session_or_channel)}
    end
  end

  defp channel_name(input, channel) do
    optional_attr_text(channel, :name) || optional_attr_text(input, :channel_name)
  end

  # A DM's peer is a durable routing fact, not a provider-specific payload
  # detail. Persist the normalized Ankole principal on the channel mirror so a
  # later system event in the same channel can declare the same conversation
  # origin without reinterpreting an old message body.
  defp put_dm_peer_principal(metadata, :im_dm, author, agent_uid) do
    case json_text(author, "principal_uid") do
      principal_uid when is_binary(principal_uid) ->
        principal_uid = normalize_uid(principal_uid)

        if principal_uid == normalize_uid(agent_uid) do
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

  defp sender_key(input, author) do
    optional_attr_text(input, :sender_key) ||
      json_text(author, "principal_uid") ||
      json_text(author, "platform_subject") ||
      json_text(author, "external_id") ||
      json_text(author, "id")
  end

  # Author resolution belongs to IdentityAdmission; the normalizer only
  # normalizes a principal uid a trusted internal caller already supplied.
  defp normalize_author_principal(%Binding{}, author) when is_map(author) do
    case json_text(author, "principal_uid") do
      principal_uid when is_binary(principal_uid) ->
        Map.put(author, "principal_uid", normalize_uid(principal_uid))

      nil ->
        author
    end
  end

  @doc false
  @spec put_author_principal(struct(), String.t()) :: struct()
  def put_author_principal(fact, principal_uid) do
    principal_uid = normalize_uid(principal_uid)
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
      nil -> validate_channel_attr_keys(Map.get(map, :channel))
      key -> {:error, {:invalid_ingress_attr_key, key}}
    end
  end

  defp validate_attr_keys(_value), do: {:error, :invalid_ingress_attrs}

  defp validate_channel_attr_keys(nil), do: :ok

  defp validate_channel_attr_keys(channel) when is_map(channel) do
    case Enum.find(Map.keys(channel), &(not is_atom(&1))) do
      nil -> :ok
      key -> {:error, {:invalid_ingress_channel_attr_key, key}}
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
    text(Map.get(map, key))
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

  defp json_text(map, key) when is_map(map) and is_binary(key), do: text(Map.get(map, key))
  defp json_text(_map, _key), do: nil

  defp normalize_raw_payload(input) do
    normalize_json_map(attr_map(input, :raw_payload, attr_map(input, :raw, %{})), :raw_payload)
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
      attr_map(channel, :raw_payload, attr_map(channel, :raw, %{})),
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

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp normalize_attachment(%{} = attachment) do
    case JSONPayload.normalize_map(attachment, allow_datetime: true) do
      {:ok, normalized} ->
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

  # An attachment is only accepted into durable state once it points at something
  # that will still resolve later: a provider/blob/storage reference, or a file
  # already materialized on the Agent Computer workspace. A raw in-memory or
  # transient attachment is rejected (see normalize_attachment/1) so the mirror
  # never stores a dangling pointer the agent can't re-fetch.
  defp durable_attachment?(attachment) do
    Enum.any?(
      [
        "provider_ref",
        "provider_file_id",
        "provider_uri",
        "blob_ref",
        "storage_ref",
        "agent_computer_path"
      ],
      &present_text?(attachment, &1)
    ) || agent_computer_visible_file_path?(attachment)
  end

  defp present_text?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp agent_computer_visible_file_path?(attachment) do
    case Map.get(attachment, "file_path") do
      path when is_binary(path) ->
        String.starts_with?(path, "/agents/") ||
          Map.get(attachment, "visible_to") == "agent_computer"

      _path ->
        false
    end
  end
end
