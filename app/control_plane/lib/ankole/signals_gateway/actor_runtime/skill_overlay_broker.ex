defmodule Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker do
  @moduledoc """
  Handles worker RPC requests for DB-backed skill overlays.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_resolve(TurnRef.t(), FabricProto.SkillOverlayResolveRequest.t(), map()) ::
          {:ok, FabricProto.SkillOverlayResponse.t()} | {:error, map()}
  def handle_resolve(
        %TurnRef{} = turn_ref,
        %FabricProto.SkillOverlayResolveRequest{} = request,
        ctx
      ) do
    with_skill(ctx, request.skill_name, fn skill_name ->
      case Library.skill_overlay(turn_ref.agent_uid, skill_name) do
        {:ok, overlay} -> {:ok, response(skill_name, overlay)}
        {:error, reason} -> error(ctx.request_id, reason, %{"skill_name" => skill_name})
      end
    end)
  end

  @spec handle_append(TurnRef.t(), FabricProto.SkillOverlayAppendRequest.t(), map()) ::
          {:ok, FabricProto.SkillOverlayResponse.t()} | {:error, map()}
  def handle_append(
        %TurnRef{} = turn_ref,
        %FabricProto.SkillOverlayAppendRequest{} = request,
        ctx
      ) do
    with_skill(ctx, request.skill_name, fn skill_name ->
      case request.content do
        content when is_binary(content) and content != "" ->
          case Library.skill_append(turn_ref.agent_uid, skill_name, content) do
            {:ok, overlay} -> {:ok, response(skill_name, overlay)}
            {:error, reason} -> error(ctx.request_id, reason, %{"skill_name" => skill_name})
          end

        _content ->
          error(ctx.request_id, :missing_content, %{"skill_name" => skill_name})
      end
    end)
  end

  @spec handle_replace(TurnRef.t(), FabricProto.SkillOverlayReplaceRequest.t(), map()) ::
          {:ok, FabricProto.SkillOverlayResponse.t()} | {:error, map()}
  def handle_replace(
        %TurnRef{} = turn_ref,
        %FabricProto.SkillOverlayReplaceRequest{} = request,
        ctx
      ) do
    with_skill(ctx, request.skill_name, fn skill_name ->
      overlay_json =
        case Common.decode_json_bytes(request.overlay_json) do
          %{} = overlay -> overlay
          _value -> %{"text" => request.content}
        end

      # An empty expected hash is the valid compare-and-swap fence for "no
      # overlay exists yet"; the resolve response reports exactly that form.
      case Library.replace_skill_overlay_cas(
             turn_ref.agent_uid,
             skill_name,
             request.expected_content_hash,
             overlay_json
           ) do
        {:ok, overlay} -> {:ok, response(skill_name, overlay)}
        {:error, reason} -> error(ctx.request_id, reason, %{"skill_name" => skill_name})
      end
    end)
  end

  defp with_skill(ctx, skill_name, fun) do
    case skill_name do
      name when is_binary(name) and name != "" -> fun.(name)
      _name -> error(ctx.request_id, :missing_skill_name, %{})
    end
  end

  defp response(skill_name, %AgentSkillOverlay{} = overlay) do
    has_overlay = is_nil(overlay.deleted_at)

    %FabricProto.SkillOverlayResponse{
      skill_name: skill_name,
      has_overlay: has_overlay,
      overlay_json: Torque.encode!(if(has_overlay, do: overlay.overlay_json || %{}, else: %{})),
      content_hash: overlay.content_hash || ""
    }
  end

  defp response(skill_name, _overlay) do
    %FabricProto.SkillOverlayResponse{
      skill_name: skill_name,
      has_overlay: false,
      overlay_json: Torque.encode!(%{}),
      content_hash: ""
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
