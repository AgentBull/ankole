defmodule Ankole.Formal.ToolResultLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.AIGateway.{ResponseItems, ToolResultJournal}
  alias Ankole.AIGateway.Schemas.Message
  @compile {:no_warn_undefined, [{ToolResultJournal, :reconcile_tool_result_items, 2}]}

  laws "Accepted production tool results preserve call identity" do
    prelude(~LEAN"""
    module
    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare
    @[expose] public section
    namespace ToolProof
    @[simp] theorem false_ne_nil :
        Lynx.Term.compare (.atom "false") (.atom "nil") ≠ .eq := by
      simp [Lynx.Term.compare_atoms]
    @[simp] theorem atom_binary (name : String) (bytes : ByteArray) (valid) :
        Lynx.Term.exactCompare (.atom name) (.bitstring bytes 0 valid) ≠ .eq := by
      intro equal
      have reversed := Std.OrientedCmp.eq_swap (cmp := Lynx.Term.exactCompare)
        (a := .atom name) (b := .bitstring bytes 0 valid)
      cases h : Lynx.Term.exactCompare (.bitstring bytes 0 valid) (.atom name) <;>
        simp_all
    end ToolProof
    """)

    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.reduce_range/5)
    cutoff(&Enum.predicate_range/5)
    cutoff(&:elixir_erl_pass.no_parens_remote/2)
    cutoff(&Kernel.inspect/1)

    law(accepted_output_matches_call(call, output),
      requires: ResponseItems.validate_client_call_output(call, output) === :ok,
      expects: ResponseItems.pair_key(call) == ResponseItems.pair_key(output),
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «accepted_output_matches_call:requires/2»] at requires
      rw [Lynx.Except.bind_eq_ok] at requires
      obtain ⟨result, accepted, hr⟩ := requires
      have hresult : result = .atom "ok" := by
        simpa [Erlang.erlang.«=:=/2»] using hr
      subst result
      unfold Elixir.Ankole.AIGateway.ResponseItems.«validate_client_call_output/2» at accepted
      cases call <;> simp [Erlang.erlang.«is_map/1», Lynx.Except.andAlso,
        Lynx.Except.guard] at accepted
      rename_i call
      cases output <;> simp [Erlang.erlang.«is_map/1», Lynx.Except.andAlso,
        Lynx.Except.guard] at accepted
      rename_i output
      repeat'
        first
        | rw [Lynx.Except.bind_eq_ok] at accepted
          obtain ⟨v, hv, accepted⟩ := accepted
        | split at accepted
        | solve
          | simp_all only [Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
              Except.ok.injEq, reduceCtorEq]
      all_goals simp_all [Lynx.apply_eq, «accepted_output_matches_call:ensures/2»,
        Erlang.erlang.«/=/2», Erlang.erlang.«==/2»]
      """
    )

    law(a_real_pair_is_accepted(),
      expects:
        ResponseItems.validate_client_call_output(
          %{"type" => "function_call", "call_id" => "a", "name" => "lookup", "arguments" => "{}"},
          %{"type" => "function_call_output", "call_id" => "a", "output" => "result"}
        ) === :ok,
      proof: ~LEAN"""
      simp +decide [Lynx.apply_eq, «a_real_pair_is_accepted:ensures/0»,
        lynx_literal_m3scp3qm, lynx_literal_voimnl7v,
        Elixir.Ankole.AIGateway.ResponseItems.lynx_literal_jyfbes47,
        Elixir.Ankole.AIGateway.ResponseItems.lynx_literal_lafpnjsy,
        Elixir.Ankole.AIGateway.ResponseItems.«validate_client_call_output/2»,
        Elixir.Ankole.AIGateway.ResponseItems.«client_call_item?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«client_output_item?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«valid_client_output?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«validate_client_output/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«valid_client_output_value?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«executable_call?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«completed_status?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«valid_optional_namespace?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«valid_caller?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«non_empty_binary?/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«pair_key/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«caller_scope/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«expected_output_type/1»,
        Elixir.Ankole.AIGateway.ResponseItems.«output_name_mismatch?/2»,
        Elixir.Access.«get/2», Elixir.Access.«get/3», Elixir.Map.«get/2», Elixir.Map.«get/3»,
        Lynx.Term.mapLookup, Lynx.Term.getMapKeys, Lynx.Term.isMember, List.find?,
        Erlang.erlang.«is_map/1», Erlang.erlang.«is_binary/1», Erlang.erlang.«is_map_key/2»,
        Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«=:=/2»,
        Lynx.Except.andAlso, Lynx.Except.guard, Lynx.Except.tryWith_ok,
        Lynx.Term.binary_exactCompare_eq, Lynx.Term.binary_compare_eq,
        ToolProof.atom_binary, Lynx.Term.exactCompare_tuple, Lynx.Term.compare_tuple,
        Std.ReflCmp.compare_self]
      """
    )
  end

  test "result sequences preserve identities or reject ambiguity" do
    call = fn id, caller ->
      %{"type" => "function_call", "call_id" => id, "name" => "lookup", "arguments" => "{}"}
      |> Map.merge(caller)
    end

    output = fn id, caller, value ->
      %{"type" => "function_call_output", "call_id" => id, "output" => value}
      |> Map.merge(caller)
    end

    program = %{"caller" => %{"type" => "program", "caller_id" => "p"}}

    anchor = %Message{
      content: [
        %{"type" => "program", "call_id" => "p", "code" => "x", "fingerprint" => "fp"},
        call.("a", %{}),
        call.("b", %{}),
        call.("a", program)
      ]
    }

    candidates = [
      output.("a", %{}, "A"),
      output.("b", %{}, "B"),
      output.("a", program, "nested A"),
      output.("missing", %{}, "orphan"),
      output.("a", %{}, "contradiction"),
      Map.put(output.("a", %{}, "A"), "name", "different_tool"),
      Map.put(output.("a", %{}, "A"), "type", "custom_tool_call_output")
    ]

    for size <- 0..3, items <- sequences(candidates, size) do
      keys = Enum.map(items, &identity/1)
      unique = Enum.uniq(items)
      conflict? = length(Enum.uniq_by(unique, &identity/1)) != length(unique)

      invalid? =
        Enum.any?(items, fn item ->
          identity(item) not in [{"a", nil}, {"b", nil}, {"a", "p"}] or
            item["type"] != "function_call_output" or
            item["name"] not in [nil, "lookup"]
        end)

      case ToolResultJournal.reconcile_tool_result_items(anchor, items) do
        {:ok, accepted} ->
          refute conflict? or invalid?, inspect(items)
          assert accepted == unique
          assert Enum.map(accepted, &identity/1) == Enum.uniq(keys)

        {:quarantine, _, _} ->
          assert conflict? or invalid?, inspect(items)
      end
    end
  end

  defp identity(item), do: {item["call_id"], get_in(item, ["caller", "caller_id"])}
  defp sequences(_values, 0), do: [[]]

  defp sequences(values, n),
    do: for(value <- values, tail <- sequences(values, n - 1), do: [value | tail])
end
