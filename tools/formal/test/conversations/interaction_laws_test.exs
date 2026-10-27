defmodule Ankole.Formal.Conversations.InteractionLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Conversations.Delivery.InteractionState

  defp closed_input?(checkpoint, id, resolution)
       when is_map(checkpoint) and is_binary(id) and is_map(resolution) do
    normalized = Ankole.Attrs.normalize_external_attrs(resolution)
    current = InteractionState.interaction(checkpoint, id)

    case {normalized, current} do
      {%{}, %{"state" => state}} -> state != "pending"
      _ -> false
    end
  end

  defp closed_input?(_, _, _), do: false

  laws "Interaction terminal preservation" do
    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.reduce_range/5)
    cutoff(&Enum.map_range/4)
    termination_suffix(&Map.do_map/2, ~LEAN"partial_fixpoint")

    law(closed_interaction_rejects_resolution(checkpoint, id, resolution),
      requires: closed_input?(checkpoint, id, resolution),
      expects: InteractionState.resolve(checkpoint, id, resolution) == :stale,
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «closed_interaction_rejects_resolution:requires/3»] at requires
      unfold «closed_input?/3» at requires
      dsimp only at requires
      cases checkpoint <;> simp [Erlang.erlang.«is_map/1», Lynx.Except.andAlso, Lynx.Except.guard] at requires
      rename_i checkpoint
      cases id <;> simp [Erlang.erlang.«is_binary/1», Lynx.Except.andAlso, Lynx.Except.guard] at requires
      rename_i bytes trailing valid
      rcases trailing with ⟨trailing, bound⟩
      cases trailing
      next =>
        cases resolution <;> simp [Erlang.erlang.«is_map/1», Erlang.erlang.«is_binary/1», Lynx.Except.andAlso, Lynx.Except.guard] at requires
        rename_i resolution
        rw [Lynx.Except.bind_eq_ok] at requires
        obtain ⟨normalized, hn, requires⟩ := requires
        rw [Lynx.Except.bind_eq_ok] at requires
        obtain ⟨current, hc, requires⟩ := requires
        split at requires
        next entries =>
          split at requires
          next state hs =>
            simp only [Erlang.erlang.«/=/2»] at requires
            simp only [Lynx.apply_eq, «closed_interaction_rejects_resolution:ensures/3»,
              Elixir.Ankole.Conversations.Delivery.InteractionState.«resolve/3»,
              Erlang.erlang.«is_map/1», Erlang.erlang.«is_binary/1»,
              Lynx.Except.andAlso, Lynx.Except.guard, Lynx.Except.ok_bind,
              Lynx.Except.tryWith_ok, hn,
              Elixir.Ankole.Conversations.Delivery.InteractionState.«interaction_state/2», hc, hs]
            simp_all [Erlang.erlang.«==/2»]
          next => simp at requires
        next => simp at requires
      next => simp at requires
      """
    )
  end

  test "all valid interaction states preserve the first terminal result during merge" do
    states = [
      %{"state" => "pending"},
      %{"state" => "answered", "answer" => %{"kind" => "free_text", "value" => ""}},
      %{
        "state" => "answered",
        "answer" => %{"kind" => "choice", "value" => "A", "option_id" => "a"}
      },
      %{"state" => "superseded"}
    ]

    for current <- states, proposed <- states do
      existing = %{"interactions" => %{"q" => current}}
      incoming = %{"interactions" => %{"q" => proposed}}
      merged = InteractionState.merge_checkpoint(existing, incoming, fn _ -> false end)
      expected = if current["state"] == "pending", do: proposed, else: current
      assert InteractionState.interaction(merged, "q") == expected
    end
  end
end
