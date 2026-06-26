defmodule Ankole.ActorRuntime.AgentProfileBroker do
  @moduledoc """
  Resolves non-secret agent profile fields for Agent Computer workers.

  actor lane fences carry only stable actor identity. Display-facing fields such
  as name and role are ordinary control-plane facts, so workers fetch them over
  RPCLane when prompt construction needs them.
  """

  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "agent-profile-#{Ecto.UUID.generate()}"

    with {:ok, turn} <- turn_ref(request),
         {agent_uid, _session_id} <- actor_identity(turn),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read),
         {:ok, profile} <- resolve_profile(request_id, agent_uid) do
      {:ok, profile}
    else
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

        {:error,
         %{
           "request_id" => request_id,
           "code" => error_code(reason),
           "message" => error_message(reason),
           "details_json" => %{"agent_uid" => agent_uid, "session_id" => session_id}
         }}
    end
  end

  def handle_request(_request, _route) do
    {:error,
     %{
       "request_id" => "",
       "code" => "invalid_agent_profile_request",
       "message" => "invalid_agent_profile_request",
       "details_json" => %{}
     }}
  end

  defp resolve_profile(request_id, agent_uid) do
    case Repo.get(Principal, String.downcase(agent_uid)) do
      %Principal{} = principal ->
        agent = Repo.get(PrincipalAgent, principal.uid)

        {:ok,
         %{
           "request_id" => request_id,
           "agent_uid" => principal.uid,
           "display_name" => principal.display_name || principal.uid,
           "role" => agent_role(agent)
         }}

      nil ->
        {:error, :agent_profile_not_found}
    end
  end

  defp agent_role(%PrincipalAgent{role: role}) when is_binary(role), do: role
  defp agent_role(_agent), do: ""

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

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "agent_profile_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
