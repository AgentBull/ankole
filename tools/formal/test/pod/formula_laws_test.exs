defmodule Ankole.Formal.Pod.FormulaLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Pod.Formula

  laws "Formula reference identity" do
    prelude(~LEAN"""
    module
    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare
    @[expose] public section
    namespace FormulaProof
    @[simp] theorem kind_ne_id :
        Lynx.Term.exactCompare
          (.bitstring ⟨#[107,105,110,100]⟩ 0 (by decide))
          (.bitstring ⟨#[105,100]⟩ 0 (by decide)) ≠ .eq := by decide
    @[simp] theorem shadowed (k old value : Lynx.Term) (tail : List (Lynx.Term × Lynx.Term)) :
        Lynx.Term.exactCompare (.map ((k,value)::(k,old)::tail)) (.map ((k,value)::tail)) = .eq := by
      apply Lynx.Term.map_exactCompare_eq_of_lookup
      intro q
      by_cases h : Lynx.Term.exactCompare q k = .eq <;>
        simp [List.find?, h, Std.ReflCmp.compare_self]
      cases ((tail.find? fun e => decide (Lynx.Term.exactCompare q e.1 = .eq)).map Prod.snd) <;>
        simp [Option.Rel, Std.ReflCmp.compare_self]
    end FormulaProof
    """)

    cutoff(&Map.new/2)
    cutoff(&Enum.map/2)
    termination_suffix(&Formula.remap_references/2, ~LEAN"partial_fixpoint")

    law(field_reference_uses_mapping(old_id, new_id),
      expects:
        Formula.remap_references(%{"kind" => "field", "id" => old_id}, %{old_id => new_id}) ===
          %{"kind" => "field", "id" => new_id},
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «field_reference_uses_mapping:ensures/2»]
      simp [Elixir.Ankole.Pod.Formula.«remap_references/2», Lynx.Term.getMapKeys,
        Erlang.erlang.«map_get/2», Erlang.erlang.«is_map/1», Erlang.maps.«get/2», Erlang.maps.«update/3», Erlang.erlang.«=:=/2»,
        Lynx.Except.tryWith_ok, Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Std.ReflCmp.compare_self]
      """
    )
  end

  test "all three-node graphs reject cycles or return dependencies before consumers" do
    ids = ~w(a b c)
    edges = for from <- ids, to <- ids, do: {from, to}

    for mask <- 0..511 do
      selected =
        edges
        |> Enum.with_index()
        |> Enum.filter(fn {_, bit} -> Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0 end)
        |> Enum.map(&elem(&1, 0))

      closure =
        Enum.reduce(ids, MapSet.new(selected), fn via, reach ->
          Enum.reduce(edges, reach, fn {from, to}, acc ->
            if MapSet.member?(reach, {from, via}) and MapSet.member?(reach, {via, to}),
              do: MapSet.put(acc, {from, to}),
              else: acc
          end)
        end)

      fields =
        Enum.map(ids, fn id ->
          refs = for {^id, target} <- selected, do: %{"kind" => "field", "id" => target}

          ast =
            Enum.reduce(refs, %{"kind" => "number", "value" => "0"}, fn ref, acc ->
              %{"kind" => "binary", "op" => "+", "left" => acc, "right" => ref}
            end)

          %{id: id, type: :formula, config: %{"ast" => ast}}
        end)

      if Enum.any?(ids, &MapSet.member?(closure, {&1, &1})) do
        assert Formula.validate_all(fields) == {:error, :formula_cycle}, "graph #{mask}"
      else
        assert {:ok, ordered} = Formula.validate_all(fields)
        assert Enum.sort(Enum.map(ordered, & &1.id)) == ids
        ranks = ordered |> Enum.with_index() |> Map.new(fn {field, rank} -> {field.id, rank} end)

        assert Enum.all?(selected, fn {consumer, dependency} ->
                 ranks[dependency] < ranks[consumer]
               end)

        mapping = %{"a" => "x", "b" => "y", "c" => "z"}

        renamed =
          Enum.map(
            fields,
            &%{
              &1
              | id: mapping[&1.id],
                config: %{"ast" => Formula.remap_references(&1.config["ast"], mapping)}
            }
          )

        assert {:ok, copied} = Formula.validate_all(renamed)
        assert Enum.map(copied, & &1.id) == Enum.map(ordered, &mapping[&1.id])
      end
    end
  end

  test "a deleted dependency is rejected before formula inference" do
    fields = [
      %{id: "a", type: :formula, config: %{"ast" => %{"kind" => "field", "id" => "missing"}}}
    ]

    assert Formula.validate_all(fields) == {:error, :unknown_formula_field}
  end
end
