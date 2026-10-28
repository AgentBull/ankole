defmodule Ankole.Formal.Pod.RecordLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Pod.Bases.Records
  @compile {:no_warn_undefined, [{Records, :field_cas, 3}]}

  laws "Production field version checks" do
    prelude(~LEAN"""
    module
    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare
    @[expose] public section
    """)

    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.reduce_range/5)
    cutoff(&:elixir_erl_pass.no_parens_remote/2)
    cutoff(&Map.take/2)

    law(matching_versions_are_accepted(versions, data),
      requires: is_map(versions) and is_map(data),
      expects: Records.field_cas(%{versions: versions}, data, versions) === :ok,
      proof: ~LEAN"""
      simp only [«matching_versions_are_accepted:requires/2»] at requires
      cases versions <;> simp [Erlang.erlang.«is_map/1», Lynx.Except.andAlso] at requires
      rename_i versions
      cases data <;> simp [Erlang.erlang.«is_map/1», Lynx.Except.andAlso] at requires
      rename_i data
      let d := Lynx.Dispatcher.ofTable Erlang.program.fun_table 100
      have uniq (xs : List Lynx.Term) (seen : List (Lynx.Term × Lynx.Term)) :
          ∃ ys, Elixir.Enum.«uniq_list/3» d (Lynx.Term.list xs) (.map seen)
            (.function 0 1 #[]) = .ok (Lynx.Term.list ys) := by
        induction xs generalizing seen with
        | nil => exact ⟨[], rfl⟩
        | cons x xs ih =>
          simp only [Lynx.Term.list, Elixir.Enum.«uniq_list/3», d,
            Erlang.program.fun_table_pure_0, Elixir.Enum.«$lynx_fun_0/1»,
            Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind]
          split
          · exact ih _
          · simp only [Erlang.maps.«put/3», Lynx.Except.ok_bind]
            obtain ⟨ys, hy⟩ := ih ((x, .atom "true") :: seen)
            exact ⟨x :: ys, by simp [d, hy, Lynx.Term.list]⟩
      have same (key : Lynx.Term) :
          Elixir.Ankole.Pod.Bases.Records.«$lynx_fun_5/3»
            (.map [(.atom "versions", .map versions)]) (.map versions) key =
              .ok Lynx.Term.false := by
        have hv : Lynx.Term.getMapKeys [.atom "versions"]
            (.map [(.atom "versions", .map versions)]) = [.map versions] := by
          simp [Lynx.Term.getMapKeys, Std.ReflCmp.compare_self]
        have total : ∃ value, Elixir.Map.«get/2» (.map versions) key = .ok value := by
          unfold Elixir.Map.«get/2» Elixir.Map.«get/3»
          dsimp only
          split
          · exact ⟨_, rfl⟩
          · exact ⟨_, rfl⟩
        obtain ⟨value, hvalue⟩ := total
        simp [Elixir.Ankole.Pod.Bases.Records.«$lynx_fun_5/3», hv, hvalue,
          Erlang.erlang.«/=/2», Std.ReflCmp.compare_self]
      have filtered (xs : List Lynx.Term) :
          Elixir.Enum.«filter_list/2» d (Lynx.Term.list xs)
            (.function 5 1 #[.map [(.atom "versions", .map versions)], .map versions]) =
              .ok Lynx.Term.nil := by
        induction xs with
        | nil => rfl
        | cons x xs ih =>
          simp only [Lynx.Term.list, Elixir.Enum.«filter_list/2», d,
            Erlang.program.fun_table_pure_5, same, Lynx.Except.ok_bind]
          simpa [Lynx.Except.guard, Lynx.Term.isMember] using ih
      obtain ⟨ys, hy⟩ := uniq
        ((Lynx.Term.mapEntries data).map Prod.fst ++ (Lynx.Term.mapEntries versions).map Prod.fst) []
      have append (xs zs : List Lynx.Term) :
          Erlang.erlang.«++/2» (Lynx.Term.list xs) (Lynx.Term.list zs) =
            .ok (Lynx.Term.list (xs ++ zs)) := by
        induction xs <;> simp_all [Lynx.Term.list, Erlang.erlang.«++/2»]
      have list_guard (xs : List Lynx.Term) :
          Erlang.erlang.«is_list/1» (Lynx.Term.list xs) = .ok Lynx.Term.true := by
        cases xs <;> rfl
      simp only [«matching_versions_are_accepted:ensures/2», Lynx.apply_eq,
        Elixir.Ankole.Pod.Bases.Records.«field_cas/3», Erlang.maps.«keys/1»,
        Lynx.Except.ok_bind, append, Elixir.Enum.«uniq/1», Elixir.Enum.«uniq_by/2»,
        Lynx.Except.pure_eq_ok, list_guard, Lynx.Except.guard, Lynx.Except.tryWith_ok]
      dsimp only [d] at hy filtered
      simp only [hy, Lynx.Except.ok_bind, Elixir.Enum.«filter/2», list_guard,
        Lynx.Except.guard, Lynx.Except.tryWith_ok, filtered]
      simp [list_guard, Lynx.Except.tryWith_ok, Lynx.Term.true, Lynx.Except.ok_bind, filtered, Erlang.erlang.«==/2»,
        Erlang.erlang.«=:=/2», Std.ReflCmp.compare_self]
      """
    )
  end

  test "all three-field version and patch combinations match an independent lookup contract" do
    keys = ~w(a b c)
    maps = assignments(keys, [:missing, 1, 2])

    for current <- maps, expected <- maps, mask <- 1..7 do
      data =
        keys
        |> Enum.with_index()
        |> Enum.filter(fn {_, bit} -> Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0 end)
        |> Map.new(fn {key, _} -> {key, "updated"} end)

      checked = MapSet.union(MapSet.new(Map.keys(data)), MapSet.new(Map.keys(expected)))
      conflicts = Enum.filter(checked, &(current[&1] != expected[&1])) |> Enum.sort()
      record = %{id: "row", versions: current, data: Map.new(keys, &{&1, "stored"})}

      case Records.field_cas(record, data, expected) do
        :ok ->
          assert conflicts == []

        {:error, {:field_conflict, result}} ->
          assert conflicts != []
          assert Enum.sort(result.fields) == conflicts
          assert result.id == record.id
          assert result.data == Map.take(record.data, conflicts)
          assert result.versions == Map.take(current, conflicts)
      end
    end
  end

  defp assignments([], _values), do: [%{}]

  defp assignments([key | rest], values) do
    for tail <- assignments(rest, values), value <- values do
      if value == :missing, do: tail, else: Map.put(tail, key, value)
    end
  end
end
