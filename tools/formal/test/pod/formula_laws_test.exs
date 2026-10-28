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
    @[simp] theorem id_ne_metadata :
        Lynx.Term.exactCompare
          (.bitstring ⟨#[105,100]⟩ 0 (by decide))
          (.bitstring ⟨#[109,101,116,97,100,97,116,97]⟩ 0 (by decide)) ≠ .eq := by decide
    @[simp] theorem kind_ne_metadata :
        Lynx.Term.exactCompare
          (.bitstring ⟨#[107,105,110,100]⟩ 0 (by decide))
          (.bitstring ⟨#[109,101,116,97,100,97,116,97]⟩ 0 (by decide)) ≠ .eq := by decide
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

    law(field_metadata_is_preserved(old_id, new_id, metadata),
      expects:
        Formula.remap_references(%{"kind" => "field", "id" => old_id, "metadata" => metadata}, %{
          old_id => new_id
        }) ===
          Map.put(%{"kind" => "field", "id" => old_id, "metadata" => metadata}, "id", new_id),
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «field_metadata_is_preserved:ensures/3»]
      simp +decide [Elixir.Ankole.Pod.Formula.«remap_references/2», Lynx.Term.getMapKeys,
        Erlang.erlang.«map_get/2», Erlang.erlang.«is_map/1», Erlang.maps.«get/2», Erlang.maps.«update/3», Erlang.maps.«put/3», Erlang.erlang.«=:=/2»,
        Lynx.Except.tryWith_ok, Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Std.ReflCmp.compare_self]
      """
    )
  end

  test "all graphs through four nodes reject cycles or preserve every dependency" do
    for count <- 1..4 do
      ids = Enum.map(1..count, &"field-#{&1}")
      edges = for from <- ids, to <- ids, do: {from, to}

      for mask <- 0..(Bitwise.bsl(1, count * count) - 1) do
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

          ranks =
            ordered |> Enum.with_index() |> Map.new(fn {field, rank} -> {field.id, rank} end)

          assert Enum.all?(selected, fn {consumer, dependency} ->
                   ranks[dependency] < ranks[consumer]
                 end)

          mapping = Map.new(ids, &{&1, "copy-" <> &1})

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
  end

  test "nested formula copies change only reference IDs and preserve evaluation" do
    mapping = %{"a" => "copy-a", "b" => "copy-b"}
    values = %{"a" => 3, "b" => -2}
    copied_values = Map.new(values, fn {id, value} -> {mapping[id], value} end)
    atoms = [literal(0), literal(5), reference("a"), reference("b")]

    for operator <- ["+", "-", "*"], left <- atoms, right <- atoms do
      expression = %{"kind" => "binary", "op" => operator, "left" => left, "right" => right}
      nested = %{"kind" => "binary", "op" => "-", "left" => expression, "right" => left}

      # A surrounding list/map exercises the production recursive traversal too.
      input = %{"formulas" => [expression, nested], "label" => "a", "enabled" => false}
      copied = Formula.remap_references(input, mapping)
      assert copied["label"] == "a"
      assert copied["enabled"] == false
      assert Enum.map(copied["formulas"], &shape/1) == Enum.map(input["formulas"], &shape/1)

      assert Enum.map(copied["formulas"], &evaluate(&1, copied_values)) ==
               Enum.map(input["formulas"], &evaluate(&1, values))

      assert Formula.remap_references(copied, Map.new(mapping, fn {a, b} -> {b, a} end)) == input
    end
  end

  defp literal(value), do: %{"kind" => "number", "value" => Integer.to_string(value)}
  defp reference(id), do: %{"kind" => "field", "id" => id, "label" => "a"}
  defp shape(%{"kind" => "field"} = node), do: Map.put(node, "id", :reference)

  defp shape(%{"kind" => "binary"} = node),
    do: %{node | "left" => shape(node["left"]), "right" => shape(node["right"])}

  defp shape(node), do: node
  defp evaluate(%{"kind" => "number", "value" => value}, _values), do: String.to_integer(value)
  defp evaluate(%{"kind" => "field", "id" => id}, values), do: Map.fetch!(values, id)

  defp evaluate(%{"kind" => "binary", "op" => op, "left" => left, "right" => right}, values) do
    a = evaluate(left, values)
    b = evaluate(right, values)

    case op do
      "+" -> a + b
      "-" -> a - b
      "*" -> a * b
    end
  end

  test "a deleted dependency is rejected before formula inference" do
    fields = [
      %{id: "a", type: :formula, config: %{"ast" => %{"kind" => "field", "id" => "missing"}}}
    ]

    assert Formula.validate_all(fields) == {:error, :unknown_formula_field}
  end
end
