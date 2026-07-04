defmodule Ankole.ActorRuntime.CodexDelegationBroker do
  @moduledoc """
  RuntimeFabric RPC broker for Codex delegation audit writes.

  The worker owns live Codex processes and queues. This broker owns the durable
  PostgreSQL audit writes those processes produce.
  """

  alias Ankole.CodexDelegations
  alias Ankole.CodexDelegations.Schemas.Delegation
  alias Ankole.CodexDelegations.Schemas.Event

  @doc """
  Handles `codex.delegation.create`.
  """
  @spec handle_create(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_create(request, _route) when is_map(request) do
    request_id = text(request, "request_id") || "codex-delegation-create-#{Ecto.UUID.generate()}"

    request
    |> Map.put_new("status", "queued")
    |> CodexDelegations.create_delegation()
    |> case do
      {:ok, %Delegation{} = delegation} ->
        {:ok, delegation_payload(request_id, delegation)}

      {:error, reason} ->
        {:error, error_payload(request_id, text(request, "agent_uid") || "", reason)}
    end
  end

  def handle_create(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_create_request)}

  @doc """
  Handles `codex.delegation.event.append`.
  """
  @spec handle_append_event(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_append_event(request, _route) when is_map(request) do
    request_id = text(request, "request_id") || "codex-delegation-event-#{Ecto.UUID.generate()}"

    request
    |> CodexDelegations.append_event()
    |> case do
      {:ok, %Event{} = event} ->
        {:ok, event_payload(request_id, event)}

      {:error, reason} ->
        {:error, error_payload(request_id, text(request, "agent_uid") || "", reason)}
    end
  end

  def handle_append_event(_request, _route),
    do: {:error, error_payload("", "", :invalid_codex_delegation_event_request)}

  @doc """
  Handles `codex.delegation.status.update`.
  """
  @spec handle_update_status(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_update_status(request, _route) when is_map(request) do
    request_id = text(request, "request_id") || "codex-delegation-update-#{Ecto.UUID.generate()}"
    delegation_id = text(request, "delegation_id")
    agent_uid = text(request, "agent_uid") || ""

    attrs =
      request
      |> Map.take(~w(status codex_thread_id result error metadata started_at completed_at))

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
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{"agent_uid" => agent_uid}
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(%Ecto.Changeset{}), do: "invalid_codex_delegation"
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "codex_delegation_failed"

  defp error_message(%Ecto.Changeset{} = changeset), do: inspect(changeset.errors)
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end
end
