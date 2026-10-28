defmodule Ankole.Formal.WorkerAckTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias AnkoleWeb.WorkerChannel
  @compile {:no_warn_undefined, [{WorkerChannel, :advance_acked, 2}]}

  laws "Production cumulative ACK stops at a gap" do
    # MapSet.new/0 uses map-backed OTP sets. The legacy tuple-set hash branch
    # and deletion after a present successor are outside this gap theorem.
    # A closed empty-set witness checks that the translated domain is inhabited.
    cutoff(&:sets.get_slot/2)
    cutoff(&MapSet.delete/2)
    termination_suffix(&WorkerChannel.advance_acked/2, ~LEAN"partial_fixpoint")

    law(gap_preserves_ack(ack, completed),
      requires: is_integer(ack) and not MapSet.member?(completed, ack + 1),
      expects: WorkerChannel.advance_acked(ack, completed) === {ack, completed},
      proof: ~LEAN"""
      cases ack <;>
        simp [Lynx.apply_eq, «gap_preserves_ack:requires/2», Erlang.erlang.«is_integer/1»,
          Erlang.erlang.«+/2_integers»] at requires
      rename_i n
      rw [Lynx.Except.bind_eq_ok] at requires
      obtain ⟨member, hm, hn⟩ := requires
      have hfalse : member = .atom "false" := by
        cases member <;> simp_all [Erlang.erlang.«not/1»]
        split at hn <;> simp_all
      subst member
      simp [Lynx.apply_eq, «gap_preserves_ack:ensures/2»,
        Elixir.AnkoleWeb.WorkerChannel.«advance_acked/2».eq_def, Erlang.erlang.«+/2_integers», hm,
        Lynx.Except.guard, Lynx.Term.isMember, Erlang.erlang.«=:=/2», Std.ReflCmp.compare_self]
      """
    )

    law(empty_set_is_a_real_gap(),
      expects: WorkerChannel.advance_acked(0, %MapSet{}) === {0, %MapSet{}},
      proof: ~LEAN"""
      simp +decide [«empty_set_is_a_real_gap:ensures/0»,
        Elixir.AnkoleWeb.WorkerChannel.«advance_acked/2».eq_def,
        Erlang.erlang.«+/2_integers», Elixir.MapSet.«member?/2», Erlang.sets.«is_element/2»,
        Lynx.Term.getMapKeys, Lynx.Term.mapLookup, List.find?, Lynx.Except.guard,
        Lynx.Term.isMember, Erlang.erlang.«=:=/2», Std.ReflCmp.compare_self]
      """
    )
  end

  test "production ACK consumes exactly the longest completed prefix" do
    for base <- [0, 17, 9_007_199_254_740_980], mask <- 0..255 do
      completed =
        for offset <- 1..8, Bitwise.band(mask, Bitwise.bsl(1, offset - 1)) != 0, do: base + offset

      prefix = Enum.take_while((base + 1)..(base + 8), &(&1 in completed))
      expected_ack = List.last(prefix) || base
      expected_pending = MapSet.new(completed -- prefix)

      assert WorkerChannel.advance_acked(base, MapSet.new(completed)) ==
               {expected_ack, expected_pending}

      assert WorkerChannel.advance_acked(expected_ack, expected_pending) ==
               {expected_ack, expected_pending}
    end
  end

  test "all five-message completion orders preserve gaps and eventually acknowledge every message" do
    for order <- permutations(Enum.to_list(1..5)) do
      {ack, pending, finished} =
        Enum.reduce(order, {0, MapSet.new(), []}, fn seq, {ack, pending, finished} ->
          finished = [seq | finished]
          {next_ack, next_pending} = WorkerChannel.advance_acked(ack, MapSet.put(pending, seq))
          expected = Enum.take_while(1..5, &(&1 in finished))
          assert next_ack == (List.last(expected) || 0)
          assert next_ack >= ack
          assert next_pending == MapSet.new(finished -- expected)
          {next_ack, next_pending, finished}
        end)

      assert ack == 5
      assert pending == MapSet.new()
      assert Enum.sort(finished) == Enum.to_list(1..5)
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(items) do
    for item <- items, rest <- permutations(List.delete(items, item)), do: [item | rest]
  end
end
