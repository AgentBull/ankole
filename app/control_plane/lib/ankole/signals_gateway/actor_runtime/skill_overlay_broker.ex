defmodule Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker do
  @moduledoc """
  Handles worker RPC requests for DB-backed skill overlays.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_resolve(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_resolve(%TurnRef{} = turn_ref, request, _route) do
    with_skill(request, fn request_id, skill_name ->
      case Library.skill_overlay(turn_ref.agent_uid, skill_name) do
        {:ok, overlay} ->
          {:ok,
           response(request_id, turn_ref.agent_uid, turn_ref.session_id, skill_name, overlay)}

        {:error, reason} ->
          error(request_id, reason, %{"skill_name" => skill_name})
      end
    end)
  end

  @spec handle_append(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_append(%TurnRef{} = turn_ref, request, _route) do
    with_skill(request, fn request_id, skill_name ->
      case RPCWire.text(request, "content", trim: false) do
        content when is_binary(content) ->
          case Library.skill_append(turn_ref.agent_uid, skill_name, content) do
            {:ok, overlay} ->
              {:ok,
               response(request_id, turn_ref.agent_uid, turn_ref.session_id, skill_name, overlay)}

            {:error, reason} ->
              error(request_id, reason, %{"skill_name" => skill_name})
          end

        nil ->
          error(request_id, :missing_content, %{"skill_name" => skill_name})
      end
    end)
  end

  @spec handle_replace(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_replace(%TurnRef{} = turn_ref, request, _route) do
    with_skill(request, fn request_id, skill_name ->
      overlay_json =
        case RPCWire.map_value(request, "overlay_json") do
          %{} = overlay -> overlay
          _value -> %{"text" => RPCWire.text(request, "content", trim: false) || ""}
        end

      case RPCWire.text(request, "expected_content_hash", trim: false) do
        expected_content_hash when is_binary(expected_content_hash) ->
          case Library.replace_skill_overlay_cas(
                 turn_ref.agent_uid,
                 skill_name,
                 expected_content_hash,
                 overlay_json
               ) do
            {:ok, overlay} ->
              {:ok,
               response(request_id, turn_ref.agent_uid, turn_ref.session_id, skill_name, overlay)}

            {:error, reason} ->
              error(request_id, reason, %{"skill_name" => skill_name})
          end

        nil ->
          error(request_id, :missing_expected_content_hash, %{"skill_name" => skill_name})
      end
    end)
  end

  defp with_skill(request, fun) do
    request_id =
      RPCWire.text(request, "request_id", trim: false) || "skill-overlay-#{Ecto.UUID.generate()}"

    case RPCWire.text(request, "skill_name", trim: false) do
      skill_name when is_binary(skill_name) -> fun.(request_id, skill_name)
      nil -> error(request_id, :missing_skill_name, %{})
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
