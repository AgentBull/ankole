defmodule Ankole.SignalsGateway.FactNormalizer do
  @moduledoc false

  alias Ankole.Principals
  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalBinding

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      fetch_datetime: 2,
      fetch_list: 2,
      fetch_map: 3,
      fetch_value: 2,
      normalize_channel_kind: 1,
      normalize_provider_lifecycle_kind: 1,
      normalize_reaction_action: 1,
      normalize_reply_mode: 1,
      normalize_uid: 1,
      optional_text: 2,
      required_text: 2,
      signal_session_id: 1,
      truthy?: 1
    ]

  def entry(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, attachments} <- normalize_attachments(input) do
      channel = fetch_map(input, :channel, %{})
      author = normalize_author_principal(binding, fetch_map(input, :author, %{}))

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         text: optional_text(input, :text),
         formatted_content: fetch_map(input, :formatted_content, %{}),
         attachments: attachments,
         links: fetch_list(input, :links),
         author: author,
         mentions: normalize_mentions(fetch_list(input, :mentions)),
         metadata: fetch_map(input, :metadata, %{}),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         explicit?:
           truthy?(fetch_value(input, :explicit)) ||
             structured_agent_mention?(input, binding.agent_uid),
         mirror_only?: truthy?(fetch_value(input, :mirror_only)),
         actor_input_type: optional_text(input, :actor_input_type),
         command_prefixes: fetch_list(input, :structured_mention_prefixes),
         sender_key: sender_key(input, author),
         gateway_time: now
       }}
    end
  end

  def lifecycle(%SignalBinding{} = binding, input, provider_lifecycle_kind, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id) do
      channel = fetch_map(input, :channel, %{})
      metadata = fetch_map(input, :metadata, %{})

      provider_lifecycle_kind =
        provider_lifecycle_kind ||
          metadata
          |> fetch_value(:provider_lifecycle_kind)
          |> normalize_provider_lifecycle_kind()

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         metadata: metadata,
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         lifecycle_kind: :removed,
         provider_lifecycle_kind: provider_lifecycle_kind,
         gateway_time: now
       }}
    end
  end

  def reaction(%SignalBinding{} = binding, input, now) do
    with {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, reaction_key} <- required_text(input, :reaction_key),
         {:ok, actor_key} <- required_text(input, :actor_key) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: optional_text(input, :ingress_event_id),
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         reaction_key: reaction_key,
         actor_key: actor_key,
         action: normalize_reaction_action(fetch_value(input, :action)),
         raw_reaction_key: optional_text(input, :raw_reaction_key) || reaction_key,
         provider_time: fetch_datetime(input, :provider_time),
         gateway_time: now
       }}
    end
  end

  def action(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- action_session_id(input),
         {:ok, action_id} <- required_text(input, :action_id) do
      signal_channel_id = optional_text(input, :signal_channel_id)
      channel = fetch_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         action_id: action_id,
         session_id: session_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: optional_text(input, :provider_entry_id),
         provider_thread_id: optional_text(input, :provider_thread_id),
         sender_key: nil,
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         actor_input_type: optional_text(input, :actor_input_type) || "signal.action.invoked",
         action: fetch_map(input, :action, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  def internal(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- required_text(input, :session_id) do
      actor_input_type =
        optional_text(input, :actor_input_type) || optional_text(input, :type) || "timer.fired"

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         session_id: session_id,
         signal_channel_id: nil,
         provider_entry_id: nil,
         provider_thread_id: nil,
         sender_key: nil,
         actor_input_type: actor_input_type,
         timer_id: optional_text(input, :timer_id),
         internal_subject: optional_text(input, :subject),
         internal: fetch_map(input, :internal, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  # The routing decision: given an accepted entry fact, what should it become?
  # Order matters — these are tried top to bottom and the first match wins:
  #   1. mirror_only: caller asked to only record, never wake the agent.
  #   2. a recognized /slash command in addressed text → command.* input.
  #   3. an adapter-supplied explicit actor_input_type (non-IM sources).
  #   4. a DM, or a group message that explicitly @-addresses the agent → a
  #      normal addressed message.
  #   5. a group reply to one of the agent's own clarifying questions → also
  #      treated as addressed (the human is answering us).
  #   6. an unaddressed group message → defer to the binding's group policy.

  defp action_session_id(input) do
    case optional_text(input, :session_id) || optional_text(input, :signal_channel_id) do
      nil ->
        {:error, :missing_session_id}

      session_or_channel ->
        {:ok, optional_text(input, :session_id) || signal_session_id(session_or_channel)}
    end
  end

  defp structured_agent_mention?(input, agent_uid) do
    input
    |> fetch_list(:mentions)
    |> Enum.any?(fn mention ->
      structured_mention?(mention, agent_uid)
    end)
  end

  # A "structured" mention is a real provider @-mention entity (not the literal
  # text "@bot"), which is what makes a group message count as explicitly
  # addressed. It must target THIS agent: either it names this agent_uid, or it
  # carries no specific uid (a generic bot mention the binding owns).
  defp structured_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(fetch_value(mention, :structured)) ||
        fetch_value(mention, :kind) in [:agent, "agent", :bot, "bot"]

    mentioned_agent = optional_text(mention, :agent_uid)

    structured? and targets_current_agent?(mention) and
      (is_nil(mentioned_agent) or normalize_uid(mentioned_agent) == agent_uid)
  end

  defp structured_mention?(_mention, _agent_uid), do: false

  defp targets_current_agent?(mention) do
    case fetch_value(mention, :targets_current_agent) do
      false -> false
      "false" -> false
      _value -> true
    end
  end

  defp normalize_mentions(mentions) do
    Enum.map(mentions, fn
      %{} = mention -> update_enum_text(mention, :kind)
      mention -> mention
    end)
  end

  defp update_enum_text(map, key) do
    case fetch_value(map, key) do
      value when is_atom(value) -> Map.put(map, key, Atom.to_string(value))
      _value -> map
    end
  end

  defp sender_key(input, author) do
    optional_text(input, :sender_key) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :platform_subject) ||
      optional_text(author, :external_id) ||
      optional_text(author, :id)
  end

  defp normalize_author_principal(%SignalBinding{} = binding, author) when is_map(author) do
    case optional_text(author, :principal_uid) do
      principal_uid when is_binary(principal_uid) ->
        Map.put(author, "principal_uid", normalize_uid(principal_uid))

      nil ->
        enrich_author_principal(binding, author)
    end
  end

  defp enrich_author_principal(%SignalBinding{} = binding, author) do
    provider =
      optional_text(author, :provider) ||
        optional_text(fetch_map(author, :metadata, %{}), :provider) ||
        binding.name

    subject =
      optional_text(author, :platform_subject) ||
        optional_text(author, :external_id)

    case {provider, subject} do
      {provider, subject} when is_binary(provider) and is_binary(subject) ->
        case Principals.resolve_platform_subject(provider, subject) do
          {:ok, principal} -> Map.put(author, "principal_uid", principal.uid)
          {:error, _reason} -> author
        end

      _missing ->
        author
    end
  end

  defp normalize_attachments(input) do
    input
    |> fetch_list(:attachments)
    |> Enum.map(&normalize_attachment/1)
    |> collect_results()
  end

  defp normalize_attachment(%{} = attachment) do
    case JsonPayload.normalize_map(attachment, allow_datetime: true) do
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
        String.starts_with?(path, "/workspace/") ||
          Map.get(attachment, "visible_to") == "agent_computer"

      _path ->
        false
    end
  end
end
