defmodule Ankole.Formal.ReferenceBudgetLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.AIGateway.Artifacts.ReferenceBudget

  laws "Production reference byte accounting", options: [maxHeartbeats: 800_000] do
    prelude(~LEAN"""
    module
    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare
    @[expose] public section
    """)

    law(exact_accumulation(current, added),
      requires: is_integer(current) and current >= 0 and is_integer(added) and added >= 0,
      expects:
        ReferenceBudget.consume(current, added) ===
          if(current + added <= 104_857_600,
            do: {:ok, current + added},
            else: {:error, :request_too_large}
          ),
      proof: ~LEAN"""
      cases current <;> cases added <;>
        simp [«exact_accumulation:requires/2», Erlang.erlang.«is_integer/1»,
          Erlang.erlang.«>=/2_integers», Lynx.Except.andAlso_eq] at requires
      rename_i current added
      repeat' (split at requires <;> simp_all)
      by_cases bound : current + added ≤ 104857600 <;>
      simp (disch := omega) [*, bound, Lynx.apply_eq, «exact_accumulation:ensures/2»,
        Elixir.Ankole.AIGateway.Artifacts.ReferenceBudget.«consume/2»,
        Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
        Erlang.erlang.«+/2_integers», Erlang.erlang.«=:=/2», Lynx.Except.andAlso,
        Lynx.Except.guard, Lynx.Except.tryWith_ok, Std.ReflCmp.compare_self]
      """
    )

    law(splitting_cannot_bypass_limit(current, first, second),
      requires:
        is_integer(current) and current >= 0 and is_integer(first) and first >= 0 and
          is_integer(second) and second >= 0,
      expects:
        with {:ok, next} <- ReferenceBudget.consume(current, first) do
          ReferenceBudget.consume(next, second)
        end === ReferenceBudget.consume(current, first + second),
      proof: ~LEAN"""
      simp only [«splitting_cannot_bypass_limit:requires/3»] at requires
      cases current <;> simp [Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
        Lynx.Except.andAlso_eq] at requires
      cases first <;> simp [Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
        Lynx.Except.andAlso_eq] at requires
      cases second <;> simp [Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
        Lynx.Except.andAlso_eq] at requires
      rename_i current first second
      repeat' (split at requires <;> simp_all)
      have sum_nonnegative : 0 ≤ first + second := by omega
      have next_nonnegative : 0 ≤ current + first := by omega
      by_cases first_bound : current + first ≤ 104857600
      all_goals by_cases total_bound : current + (first + second) ≤ 104857600
      all_goals try omega
      all_goals
      simp (disch := omega) [*, sum_nonnegative, next_nonnegative, first_bound, total_bound, Int.add_assoc, Lynx.apply_eq, «splitting_cannot_bypass_limit:ensures/3»,
        Elixir.Ankole.AIGateway.Artifacts.ReferenceBudget.«consume/2»,
        Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
        Erlang.erlang.«+/2_integers», Erlang.erlang.«=:=/2», Lynx.Except.andAlso,
        Lynx.Except.guard, Lynx.Except.tryWith_ok, Std.ReflCmp.compare_self]
      all_goals split <;> simp_all [Std.ReflCmp.compare_self]
      """
    )
  end
end
