defmodule Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker do
  @moduledoc """
  Handles worker RPC requests for the rendered skill-lesson block.

  The wire name stays `skills.overlay.resolve` because the worker-side
  composition contract is unchanged: one text block per skill, appended
  under the `Agent-specific additions` separator. Lessons are written by
  Dreaming and the Console only, so the append and replace methods are gone.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_resolve(TurnRef.t(), FabricProto.SkillOverlayResolveRequest.t(), map()) ::
          {:ok, FabricProto.SkillOverlayResolveResponse.t()} | {:error, map()}
  def handle_resolve(
        %TurnRef{} = turn_ref,
        %FabricProto.SkillOverlayResolveRequest{} = request,
        ctx
      ) do
    case Library.rendered_skill_lessons(turn_ref.agent_uid, request.skill_names) do
      {:ok, rendered} ->
        responses =
          rendered
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {skill_name, entry} -> response(skill_name, entry) end)

        {:ok, %FabricProto.SkillOverlayResolveResponse{overlays: responses}}

      {:error, reason} ->
        error(ctx.request_id, reason, %{"skill_names" => request.skill_names})
    end
  end

  defp response(skill_name, entry) do
    %FabricProto.SkillOverlayResponse{
      skill_name: skill_name,
      has_overlay: entry["has_lessons"],
      overlay_json: Torque.encode!(%{"text" => entry["text"]}),
      content_hash: entry["content_hash"]
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
