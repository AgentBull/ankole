defmodule Ankole.ActorRuntime.LlmCredentialBroker do
  @moduledoc """
  Handles worker runtime credential RPC requests.

  The broker re-resolves the agent model profile on the control-plane side. The
  worker's `TurnStart` model ref is only a sanity hint, not the lookup key.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo

  # Allowed credential request purposes. `ai_turn`/`codex_subagent` are real
  # in-session work and must prove the route is assigned to the actor;
  # `live_check` is a connectivity probe that is allowed without an assignment.
  @purposes ~w(ai_turn codex_subagent live_check)

  @doc """
  Resolves and returns LLM provider credentials for a worker's RPC request.

  Always returns `{:ok, envelope}` for a well-formed request: failures (bad
  purpose, unauthorized route, missing provider) are encoded as a `rejected`
  envelope rather than an error tuple, so the worker always gets a reply it can
  act on. The plaintext credential is decrypted here and handed to the worker
  over the (ephemeral) RPC lane; the control plane re-resolves the model profile
  itself rather than trusting the worker's requested profile as the lookup key.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "llm-credential-#{Ecto.UUID.generate()}"
    agent_uid = text(request, "agent_uid") || ""
    session_id = text(request, "session_id") || ""
    profile = text(request, "profile") || ""
    purpose = text(request, "purpose") || "ai_turn"

    result =
      with :ok <- validate_purpose(purpose),
           :ok <- authorize_route(agent_uid, session_id, route, purpose),
           {:ok, runtime_profile} <- ModelProfiles.resolve_runtime_profile(agent_uid, profile),
           {:ok, credential} <-
             runtime_profile
             |> Map.fetch!("provider")
             |> LlmProviders.plaintext_credential(),
           {:ok, connection_options} <- Map.fetch(runtime_profile, "connection_options") do
        {:ok, {runtime_profile, credential, connection_options}}
      end

    case result do
      {:ok, {runtime_profile, credential, connection_options}} ->
        {:ok,
         response_envelope(
           request_id,
           session_id,
           runtime_profile,
           credential,
           connection_options
         )}

      {:error, reason} ->
        {:ok, rejected_envelope(request_id, agent_uid, session_id, profile, reason)}
    end
  end

  def handle_request(_request, _route), do: {:error, :invalid_credential_request}

  # Connectivity probes are not tied to a session, so they skip the
  # worker-assignment check. Real turn purposes fall through to the clause below.
  defp authorize_route(_agent_uid, _session_id, _route, "live_check"), do: :ok

  # Authorizes a credential request by proving the requesting route currently
  # owns a live assignment for this actor. A worker cannot fetch credentials for
  # a session it was never assigned, even if it knows the agent/session ids.
  defp authorize_route(agent_uid, session_id, route, _purpose) do
    case Repo.transact(fn repo ->
           with %AgentComputerWorker{} = worker <- worker_by_route(repo, route),
                %ActorSessionWorkerAssignment{} <-
                  live_assignment(repo, agent_uid, session_id, worker) do
             {:ok, :authorized}
           else
             nil -> {:error, :worker_not_assigned_to_actor}
           end
         end) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp worker_by_route(repo, route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.status in ["ready", "draining"])
    |> repo.one()
  end

  defp live_assignment(repo, agent_uid, session_id, %AgentComputerWorker{} = worker) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^String.downcase(agent_uid))
    |> where([assignment], assignment.session_id == ^session_id)
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where(
      [assignment],
      is_nil(assignment.worker_instance_id) or
        assignment.worker_instance_id == ^worker.worker_instance_id
    )
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.one()
  end

  defp validate_purpose(purpose) when purpose in @purposes, do: :ok
  defp validate_purpose(_purpose), do: {:error, :invalid_credential_purpose}

  defp response_envelope(request_id, session_id, runtime_profile, credential, connection_options) do
    agent_uid = runtime_profile["agent_uid"]

    %{
      "protocol_version" => 1,
      "message_id" => "llm-credential-response-#{Ecto.UUID.generate()}",
      "correlation_id" => request_id,
      "lane" => "LANE_RPC",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "llm_provider_credential_response",
        "llm_provider_credential_response" => %{
          "request_id" => request_id,
          "agent_uid" => agent_uid,
          "session_id" => session_id,
          "profile" => runtime_profile["profile"],
          "provider_id" => runtime_profile["provider_id"],
          "provider_source" => runtime_profile["provider_source"],
          "model" => runtime_profile["model"],
          "base_url" => connection_options["base_url"] || "",
          "connection_options_json" => connection_options,
          "provider_options_json" => runtime_profile["provider_options"] || %{},
          "credential" => credential,
          "credential_mode" => runtime_profile["credential_mode"],
          "source_metadata_json" => runtime_profile["source_metadata"] || %{}
        }
      }
    }
  end

  defp rejected_envelope(request_id, agent_uid, session_id, profile, reason) do
    %{
      "protocol_version" => 1,
      "message_id" => "llm-credential-rejected-#{Ecto.UUID.generate()}",
      "correlation_id" => request_id,
      "lane" => "LANE_RPC",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "llm_provider_credential_rejected",
        "llm_provider_credential_rejected" => %{
          "request_id" => request_id,
          "agent_uid" => agent_uid,
          "session_id" => session_id,
          "profile" => profile,
          "code" => error_code(reason),
          "message" => error_message(reason)
        }
      }
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "credential_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message({reason, details}), do: "#{inspect(reason)}: #{inspect(details)}"
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
