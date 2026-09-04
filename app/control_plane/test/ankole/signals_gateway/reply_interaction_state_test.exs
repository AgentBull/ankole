defmodule Ankole.SignalsGateway.ReplyInteractionStateTest do
  @moduledoc false
  # `merge_checkpoint/3` is the one place that projects a resolved interaction
  # into the stored presentation and decides whether a provider surface needs a
  # corrective refresh. The adapter answers the surface question; the state
  # machine never reads provider keys.
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation

  @interaction_id "clarify:merge"
  @now ~U[2026-09-04 09:00:00.000000Z]

  defp pending_checkpoint do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.interaction_request("event-1", %{
        "body" => "Choose a team",
        "choices" => [%{"id" => "operators", "label" => "Operators"}],
        "control_id" => "team",
        "interaction_id" => @interaction_id,
        "version" => 1
      })

    ReplyInteractionState.initialize(%{"message_id" => "m1"}, presentation, @now)
  end

  defp answered(checkpoint) do
    {:ok, resolved} =
      ReplyInteractionState.resolve(checkpoint, @interaction_id, %{
        "state" => "answered",
        "answer" => %{"kind" => "choice", "value" => "Operators", "option_id" => "operators"},
        "resolved_at" => DateTime.to_iso8601(@now)
      })

    resolved
  end

  test "a resolved interaction projects into the presentation and refreshes an existing surface" do
    pending = pending_checkpoint()
    merged = ReplyInteractionState.merge_checkpoint(pending, answered(pending), fn _ -> true end)

    assert merged["presentation"]["interaction_status"] == "answered"
    assert merged["previous_presentation"]["interaction_status"] == "pending"
    assert merged["refresh_pending"] == true
    assert merged["refresh_reason"] == "interaction"
  end

  test "the same resolution without a provider surface schedules no refresh" do
    pending = pending_checkpoint()
    merged = ReplyInteractionState.merge_checkpoint(pending, answered(pending), fn _ -> false end)

    assert merged["presentation"]["interaction_status"] == "answered"
    refute Map.has_key?(merged, "refresh_pending")
  end

  test "an unchanged projection never asks about the surface" do
    pending = pending_checkpoint()

    merged =
      ReplyInteractionState.merge_checkpoint(pending, pending, fn _ ->
        flunk("surface question asked for an unchanged projection")
      end)

    assert merged == pending
  end

  test "a late pending write cannot reopen an answered interaction" do
    pending = pending_checkpoint()
    stored = ReplyInteractionState.merge_checkpoint(pending, answered(pending), fn _ -> true end)

    late = ReplyInteractionState.merge_checkpoint(stored, pending, fn _ -> true end)

    assert ReplyInteractionState.interaction(late, @interaction_id)["state"] == "answered"
    assert late["presentation"]["interaction_status"] == "answered"
    assert late["refresh_pending"] == true
  end
end
