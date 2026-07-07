defmodule Ankole.ActorRuntime.CodexDelegationBroker do
  @moduledoc """
  RuntimeFabric RPC broker for Codex delegation audit writes.

  The worker owns live Codex processes and queues. This broker owns the durable
  PostgreSQL audit writes those processes produce.
  """

  alias Ankole.ActorRuntime.RPCWire
  alias Ankole.CodexDelegations
  alias Ankole.CodexDelegations.Schemas.Delegation
  alias Ankole.CodexDelegations.Schemas.Event

  @terminal_statuses ~w(succeeded failed stopped)

  @doc """
  Handles `codex.delegation.create`.
  """
  @spec handle_create(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_create(request, route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id") || "codex-delegation-create-#{Ecto.UUID.generate()}"

    request
    |> Map.put_new("status", "queued")
    |> put_worker_route_metadata(route)
    |> CodexDelegations.create_delegation()
    |> case do
      {:ok, %Delegation{} = delegation} ->
        {:ok, delegation_payload(request_id, delegation)}

      {:error, reason} ->
        {:error, error_payload(request_id, RPCWire.text(request, "agent_uid") || "", reason)}
    end
  end

  def handle_create(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_create_request)}

  @doc """
  Handles `codex.delegation.get`.
  """
  @spec handle_get(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_get(request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id") || "codex-delegation-get-#{Ecto.UUID.generate()}"

    delegation_id = RPCWire.text(request, "delegation_id")
    agent_uid = RPCWire.text(request, "agent_uid") || ""

    case CodexDelegations.get_delegation_summary_for_agent(delegation_id || "", agent_uid) do
      {:ok, %{delegation: %Delegation{} = delegation, last_event_seq: last_event_seq}} ->
        payload =
          request_id
          |> delegation_payload(delegation)
          |> maybe_put("last_event_seq", last_event_seq)
          |> maybe_put_result_ref(delegation)

        {:ok, payload}

      {:error, reason} ->
        {:error, error_payload(request_id, agent_uid, reason)}
    end
  end

  def handle_get(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_get_request)}

  @doc """
  Handles `codex.delegation.event.append`.
  """
  @spec handle_append_event(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_append_event(request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id") || "codex-delegation-event-#{Ecto.UUID.generate()}"

    request
    |> CodexDelegations.append_event()
    |> case do
      {:ok, %Event{} = event} ->
        {:ok, event_payload(request_id, event)}

      {:error, reason} ->
        {:error, error_payload(request_id, RPCWire.text(request, "agent_uid") || "", reason)}
    end
  end

  def handle_append_event(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_event_request)}

  @doc """
  Handles `codex.delegation.status.update`.
  """
  @spec handle_update_status(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_update_status(request, route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id") || "codex-delegation-update-#{Ecto.UUID.generate()}"

    delegation_id = RPCWire.text(request, "delegation_id")
    agent_uid = RPCWire.text(request, "agent_uid") || ""

    attrs =
      request
      |> Map.take(~w(status codex_thread_id result error metadata started_at completed_at))
      |> put_worker_route_metadata(route)

    case CodexDelegations.update_delegation(delegation_id || "", agent_uid, attrs) do
      {:ok, %Delegation{} = delegation} ->
        {:ok, delegation_payload(request_id, delegation)}

      {:error, reason} ->
        {:error, error_payload(request_id, agent_uid, reason)}
    end
  end

  def handle_update_status(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_update_request)}

  defp delegation_payload(request_id, %Delegation{} = delegation) do
    %{
      "request_id" => request_id,
      "delegation_id" => delegation.id,
      "agent_uid" => delegation.agent_uid,
      "session_id" => delegation.session_id,
      "workdir" => delegation.workdir,
      "status" => delegation.status,
      "codex_thread_id" => delegation.codex_thread_id,
      "queued_at" => iso8601(delegation.queued_at),
      "started_at" => iso8601(delegation.started_at),
      "completed_at" => iso8601(delegation.completed_at),
      "result" => delegation.result || %{},
      "error" => delegation.error || %{},
      "metadata" => delegation.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_payload(request_id, %Event{} = event) do
    %{
      "request_id" => request_id,
      "delegation_id" => event.delegation_id,
      "agent_uid" => event.agent_uid,
      "seq" => event.seq,
      "event_id" => event.id
    }
  end

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "codex_delegation_failed",
      changeset_code: "invalid_codex_delegation",
      message_style: :tuple_inspect,
      details_json: %{"agent_uid" => agent_uid}
    )
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_result_ref(map, %Delegation{status: status, id: id})
       when status in @terminal_statuses do
    Map.put(map, "result_ref", %{"type" => "codex_delegation", "delegation_id" => id})
  end

  defp maybe_put_result_ref(map, %Delegation{}), do: map

  defp put_worker_route_metadata(map, route) when is_map(map) and is_binary(route) do
    metadata = RPCWire.map_value(map, "metadata", %{})
    Map.put(map, "metadata", Map.put(metadata, "worker_route", route))
  end

  defp put_worker_route_metadata(map, _route), do: map
end
