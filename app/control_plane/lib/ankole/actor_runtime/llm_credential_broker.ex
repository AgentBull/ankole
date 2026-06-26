defmodule Ankole.ActorRuntime.LlmCredentialBroker do
  @moduledoc """
  Handles worker runtime credential RPC requests.

  The broker re-resolves the agent model profile on the control-plane side. The
  worker's `TurnStart` model ref is only a sanity hint, not the lookup key.
  """

  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.ActorRuntime.WorkerRouteAuth

  # Allowed credential request purposes. Every purpose is still bound to the
  # live worker assignment so provider credentials cannot be fetched from a
  # route that is merely connected to the actor lane.
  @purposes ~w(ai_turn codex_subagent live_check)

  @doc """
  Resolves and returns LLM provider credentials for a worker's RPC request.

  Returns either the success payload for `llm_provider.resolve_credential` or a
  method-level error. RPCLane owns the fabric envelope around that result.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "llm-credential-#{Ecto.UUID.generate()}"
    profile = text(request, "profile") || ""
    purpose = text(request, "purpose") || "ai_turn"

    result =
      with {:ok, turn} <- turn_ref(request),
           {agent_uid, session_id} <- actor_identity(turn),
           :ok <- validate_purpose(purpose),
           :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read),
           {:ok, runtime_profile} <- ModelProfiles.resolve_runtime_profile(agent_uid, profile),
           {:ok, credential} <-
             runtime_profile
             |> Map.fetch!("provider")
             |> LlmProviders.plaintext_credential(),
           {:ok, connection_options} <- Map.fetch(runtime_profile, "connection_options") do
        {:ok, {session_id, runtime_profile, credential, connection_options}}
      end

    case result do
      {:ok, {session_id, runtime_profile, credential, connection_options}} ->
        {:ok,
         response_payload(
           request_id,
           session_id,
           runtime_profile,
           credential,
           connection_options
         )}

      {:error, reason} ->
        {agent_uid, session_id} =
          request
          |> turn_ref()
          |> case do
            {:ok, turn} ->
              actor_identity(turn)

            {:error, _reason} ->
              {text(request, "agent_uid") || "", text(request, "session_id") || ""}
          end

        {:error, error_payload(request_id, agent_uid, session_id, profile, reason)}
    end
  end

  def handle_request(_request, _route),
    do: {:error, error_payload("", "", "", "", :invalid_credential_request)}

  defp validate_purpose(purpose) when purpose in @purposes, do: :ok
  defp validate_purpose(_purpose), do: {:error, :invalid_credential_purpose}

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp actor_identity(%{"actor" => %{"agent_uid" => agent_uid, "session_id" => session_id}})
       when is_binary(agent_uid) and is_binary(session_id),
       do: {agent_uid, session_id}

  defp actor_identity(_turn), do: {"", ""}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  defp response_payload(request_id, session_id, runtime_profile, credential, connection_options) do
    agent_uid = runtime_profile["agent_uid"]

    %{
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
  end

  defp error_payload(request_id, agent_uid, session_id, profile, reason) do
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{
        "agent_uid" => agent_uid,
        "session_id" => session_id,
        "profile" => profile
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
