defmodule Ankole.ActorRuntime.SkillOverlayBroker do
  @moduledoc """
  Handles worker RPC requests for DB-backed skill overlays.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.ActorRuntime.RPCWire
  alias Ankole.ActorRuntime.TurnRef

  @spec handle_request(String.t(), TurnRef.t(), map(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def handle_request(action, %TurnRef{} = turn_ref, request, _route)
      when action in ["resolve", "replace"] and is_map(request) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) || "skill-overlay-#{Ecto.UUID.generate()}"

    with skill_name when is_binary(skill_name) <-
           RPCWire.text(request, "skill_name", trim: false) do
      dispatch_action(
        action,
        request_id,
        turn_ref.agent_uid,
        turn_ref.session_id,
        skill_name,
        request
      )
    else
      nil -> error(request_id, :missing_skill_name, %{})
    end
  end

  def handle_request(_action, _turn_ref, _request, _route),
    do: error("", :invalid_skill_overlay_request, %{})

  defp dispatch_action("resolve", request_id, agent_uid, session_id, skill_name, _request) do
    case Library.skill_overlay(agent_uid, skill_name) do
      {:ok, overlay} -> {:ok, response(request_id, agent_uid, session_id, skill_name, overlay)}
      {:error, reason} -> error(request_id, reason, %{"skill_name" => skill_name})
    end
  end

  defp dispatch_action("replace", request_id, agent_uid, session_id, skill_name, request) do
    overlay_json =
      case RPCWire.map_value(request, "overlay_json") do
        %{} = overlay -> overlay
        _value -> %{"text" => RPCWire.text(request, "content", trim: false) || ""}
      end

    case Library.replace_skill_overlay(agent_uid, skill_name, overlay_json) do
      {:ok, overlay} -> {:ok, response(request_id, agent_uid, session_id, skill_name, overlay)}
      {:error, reason} -> error(request_id, reason, %{"skill_name" => skill_name})
    end
  end

  defp response(request_id, agent_uid, session_id, skill_name, %AgentSkillOverlay{} = overlay) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "skill_name" => skill_name,
      "has_overlay" => is_nil(overlay.deleted_at),
      "overlay_json" =>
        if(is_nil(overlay.deleted_at), do: overlay.overlay_json || %{}, else: %{}),
      "content_hash" => overlay.content_hash || ""
    }
  end

  defp response(request_id, agent_uid, session_id, skill_name, _overlay) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "session_id" => session_id,
      "skill_name" => skill_name,
      "has_overlay" => false,
      "overlay_json" => %{},
      "content_hash" => ""
    }
  end

  defp error(request_id, reason, details) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "skill_overlay_request_failed",
       message_style: :tuple_inspect,
       details_json: details
     )}
  end
end
