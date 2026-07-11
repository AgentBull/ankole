defmodule Ankole.SubagentDelegations.Audit do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Attrs
  alias Ankole.SubagentDelegations.Lifecycle
  alias Ankole.SubagentDelegations.Queries
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Schemas.Event
  alias Ankole.SubagentDelegations.Text

  @max_event_payload_bytes 16_384
  @event_payload_preview_bytes 7_000
  @sensitive_keys MapSet.new(~w(
                    authorization
                    api_key
                    openai_api_key
                    ankole_aigateway_api_key
                    access_token
                    refresh_token
                    id_token
                    auth_token
                    bearer_token
                    token
                    codex_access_token
                  ))

  @spec append_event(map()) :: {:ok, Event.t()} | {:error, term()}
  def append_event(attrs) when is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         %Delegation{} = delegation <-
           Queries.get_for_agent(Attrs.text(attrs, "delegation_id"), agent_uid) do
      append_event_in_tx(Repo, delegation, attrs, agent_uid)
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec append_events(String.t(), String.t(), [map()]) :: {:ok, [Event.t()]} | {:error, term()}
  def append_events(delegation_id, agent_uid, events)
      when is_binary(delegation_id) and is_binary(agent_uid) and is_list(events) do
    with :ok <- require_nonempty_events(events),
         {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         %Delegation{} = delegation <- Queries.get_for_agent(delegation_id, agent_uid) do
      Repo.transact(fn repo ->
        append_events_in_tx(repo, delegation, agent_uid, events)
      end)
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec append_worker_events(String.t(), String.t(), [map()], TurnRef.t(), String.t()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def append_worker_events(delegation_id, agent_uid, events, %TurnRef{} = turn_ref, route)
      when is_binary(delegation_id) and is_binary(agent_uid) and is_list(events) and
             is_binary(route) do
    with :ok <- require_nonempty_events(events),
         {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      Repo.transact(fn repo ->
        # Match placement's worker-row prefix before taking the shared
        # agent/delegation locks; old-attempt audit cannot deadlock recovery.
        with {:ok, :authorized} <-
               WorkerRouteAuth.authorize_turn_route_in_tx(
                 repo,
                 turn_ref,
                 route,
                 :write,
                 lock: true
               ),
             :ok <- Lifecycle.lock_agent_slots_in_tx(repo, agent_uid),
             %Delegation{} = delegation <-
               Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE") do
          append_events_in_tx(repo, delegation, agent_uid, events)
        else
          nil -> {:error, :delegation_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp append_events_in_tx(repo, delegation, agent_uid, events) do
    events
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, appended} ->
      case append_event_in_tx(repo, delegation, Attrs.normalize(attrs), agent_uid) do
        {:ok, %Event{} = event} -> {:cont, {:ok, [event | appended]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, appended} -> {:ok, Enum.reverse(appended)}
      {:error, _reason} = error -> error
    end
  end

  defp require_nonempty_events([]), do: {:error, :subagent_event_batch_empty}

  defp require_nonempty_events([_event | _rest] = events) do
    if length(events) <= 20, do: :ok, else: {:error, :subagent_event_batch_too_large}
  end

  defp append_event_in_tx(repo, delegation, attrs, agent_uid) do
    {redacted_payload, redaction} =
      attrs
      |> Map.get("payload", %{})
      |> redact_payload()

    {payload, truncation} = bound_event_payload(redacted_payload)

    event_attrs =
      attrs
      |> Map.put("agent_uid", agent_uid)
      |> Map.put("delegation_id", delegation.id)
      |> Map.put("payload", payload)
      |> Map.put(
        "redaction",
        attrs
        |> Map.get("redaction")
        |> merge_redaction(Map.merge(redaction, truncation))
      )
      |> Map.put_new("occurred_at", now())

    event_changeset = Event.changeset(%Event{}, event_attrs)

    case repo.insert(event_changeset) do
      {:ok, %Event{} = event} ->
        {:ok, event}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_append_conflict(repo, changeset, delegation.id, event_attrs)
    end
  end

  defp handle_append_conflict(repo, changeset, delegation_id, event_attrs) do
    if delegation_seq_conflict?(changeset) do
      case repo.get_by(Event, delegation_id: delegation_id, seq: Map.get(event_attrs, "seq")) do
        %Event{} = event ->
          if same_audit_event?(event, event_attrs) do
            {:ok, event}
          else
            {:error, :subagent_event_sequence_conflict}
          end

        nil ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp same_audit_event?(event, attrs) do
    event.direction == Map.get(attrs, "direction") and
      event.event_type == Map.get(attrs, "event_type") and
      event.payload == Map.get(attrs, "payload") and
      event.redaction == Map.get(attrs, "redaction")
  end

  defp delegation_seq_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) ==
            "subagent_delegation_events_delegation_seq_index"

      _error ->
        false
    end)
  end

  defp redact_payload(payload) when is_map(payload) do
    {redacted, paths} = redact_value(payload, [])

    redaction =
      case paths do
        [] -> %{}
        paths -> %{"redacted_paths" => Enum.reverse(paths)}
      end

    {redacted, redaction}
  end

  defp redact_payload(_payload), do: {%{"value" => nil}, %{"redacted_paths" => ["$"]}}

  defp bound_event_payload(payload) do
    encoded = Ankole.JSON.encode!(payload)

    if byte_size(encoded) <= @max_event_payload_bytes do
      {payload, %{}}
    else
      preview = Text.utf8_prefix(encoded, @event_payload_preview_bytes)

      {
        %{
          "truncated" => true,
          "preview_json" => preview,
          "original_bytes" => byte_size(encoded)
        },
        %{
          "payload_truncated" => true,
          "original_payload_bytes" => byte_size(encoded)
        }
      }
    end
  end

  defp redact_value(%{} = value, path) do
    Enum.reduce(value, {%{}, []}, fn {key, nested}, {acc, paths} ->
      key_text = to_string(key)
      next_path = path ++ [key_text]

      if sensitive_key?(key_text) do
        redacted = redacted_value(nested)
        {Map.put(acc, key_text, redacted), [json_path(next_path) | paths]}
      else
        {redacted, nested_paths} = redact_value(nested, next_path)
        {Map.put(acc, key_text, redacted), nested_paths ++ paths}
      end
    end)
  end

  defp redact_value(values, path) when is_list(values) do
    {values, indexed_paths, _index} =
      Enum.reduce(values, {[], [], 0}, fn nested, {acc, paths, index} ->
        {redacted, nested_paths} = redact_value(nested, path ++ [Integer.to_string(index)])
        {[redacted | acc], nested_paths ++ paths, index + 1}
      end)

    {Enum.reverse(values), indexed_paths}
  end

  defp redact_value(value, _path), do: {value, []}

  defp sensitive_key?(key) do
    normalized = key |> String.downcase() |> String.replace("-", "_")
    MapSet.member?(@sensitive_keys, normalized)
  end

  defp redacted_value(value) do
    digest =
      value
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "[REDACTED:sha256=#{digest}]"
  end

  defp merge_redaction(existing, generated) when is_map(existing) and map_size(generated) > 0,
    do: Map.merge(existing, generated)

  defp merge_redaction(existing, _generated) when is_map(existing), do: existing
  defp merge_redaction(_existing, generated), do: generated

  defp json_path(parts), do: "$." <> Enum.join(parts, ".")
  defp now, do: DateTime.utc_now(:microsecond)
end
