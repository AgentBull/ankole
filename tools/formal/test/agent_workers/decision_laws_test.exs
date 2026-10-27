defmodule Ankole.Formal.AgentWorkers.DecisionLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.AgentWorkers.Decision
  alias Ankole.AgentWorkers.ProviderKind

  defp has_worker_observation_keys?(worker, observation) do
    is_map(worker) and is_map_key(worker, :generation) and is_map_key(worker, :instance_ref) and
      is_map(observation) and is_map_key(observation, :generation) and
      is_map_key(observation, :instance_ref)
  end

  defp expected_current_instance?(worker, observation) do
    wg = :erlang.map_get(:generation, worker)
    wi = :erlang.map_get(:instance_ref, worker)
    og = :erlang.map_get(:generation, observation)
    oi = :erlang.map_get(:instance_ref, observation)

    wg != nil and og == wg and (wi == nil or oi == wi)
  end

  defp has_boolean_pause?(definition) do
    is_map(definition) and is_map_key(definition, :pause) and
      is_boolean(:erlang.map_get(:pause, definition))
  end

  defp expected_pause_release?(definition, reason) do
    :erlang.map_get(:pause, definition) == true and
      (reason === "idle_release" or reason === "agent_inactive")
  end

  defp observation_list?([], _worker), do: true

  defp observation_list?([object | rest], worker),
    do: has_worker_observation_keys?(worker, object) and observation_list?(rest, worker)

  defp observation_list?(_objects, _worker), do: false

  defp cleanup_input?(%{worker: worker, objects: objects}),
    do: observation_list?(objects, worker)

  defp cleanup_input?(_facts), do: false

  defp expected_cleanup(%{worker: worker, objects: objects}) do
    {matching, stray} = Enum.split_with(objects, &ProviderKind.current_instance?(worker, &1))

    case matching do
      [_first, extra | _] -> {:delete_object, extra}
      _ -> if stray == [], do: :none, else: {:delete_object, hd(stray)}
    end
  end

  laws "Decision production cleanup contract" do
    # The contract uses proper lists and returns before lifecycle decisions.
    # A successful Lean result proves that none of these cutoffs is reached.
    cutoff(&:elixir_erl_pass.no_parens_remote/2)
    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.reduce_range/5)
    cutoff(&Decision.partial/2)
    cutoff(&Decision.deleting/2)
    cutoff(&Decision.wanted?/1)
    cutoff(&Decision.connected?/1)
    cutoff(&Decision.draining/2)
    cutoff(&Decision.paused/2)
    cutoff(&Decision.running/2)

    law(production_cleanup_matches_spec(facts),
      requires: cleanup_input?(facts) and expected_cleanup(facts) != :none,
      expects: Decision.next(facts) === expected_cleanup(facts),
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «production_cleanup_matches_spec:requires/1»] at requires
      rw [Lynx.Except.bind_eq_ok] at requires
      obtain ⟨valid, hv, hreq⟩ := requires
      have hvtrue : valid = Lynx.Term.true := by
        cases valid <;> simp_all
        split at hreq <;> simp_all
      subst hvtrue
      unfold «cleanup_input?/1» at hv
      dsimp only at hv
      split at hv
      next objects worker hkeys =>
        let d := Lynx.Dispatcher.ofTable Erlang.program.fun_table 100
        -- The two closures invoke the same translated production matcher.
        -- Induction connects their complete Enum.split_with executions.
        have hfold (xs : List Lynx.Term) (acc : Lynx.Term) :
            Elixir.Enum.«lynx_local_2/3» d (Lynx.Term.list xs) acc
                (.function 1 2 #[.function 5 1 #[worker]]) =
            Elixir.Enum.«lynx_local_2/3» d (Lynx.Term.list xs) acc
                (.function 1 2 #[.function 0 1 #[worker]]) := by
          induction xs generalizing acc with
          | nil => rfl
          | cons x xs ih =>
            simp only [Lynx.Term.list, Elixir.Enum.«lynx_local_2/3»]
            simp only [d, Erlang.program.fun_table_pure_1,
              Elixir.Enum.«$lynx_fun_1/3», Erlang.program.fun_table_pure_5,
              Erlang.program.fun_table_pure_0,
              Elixir.Ankole.AgentWorkers.Decision.«$lynx_fun_5/2», «$lynx_fun_0/2»]
            cases acc <;> simp
            rename_i entries
            rcases entries with ⟨entries⟩
            cases entries with
            | nil => rfl
            | cons a tail =>
              cases tail with
              | nil => rfl
              | cons b tail =>
                cases tail with
                | cons _ _ => rfl
                | nil =>
                  cases hc : Elixir.Ankole.AgentWorkers.ProviderKind.«current_instance?/2» worker x with
                  | error e => simp [hc]
                  | ok v =>
                    simp only [hc, Lynx.Except.ok_bind]
                    split <;> exact ih _
        have hlist : ∀ t : Lynx.Term, «observation_list?/2» t worker = .ok Lynx.Term.true →
            ∃ xs, t = Lynx.Term.list xs := by
          intro t
          induction t using Lynx.Term.induct with
          | cons x xs hx ih =>
            intro h
            simp only [«observation_list?/2»] at h
            cases hc : «has_worker_observation_keys?/2» worker x with
            | error e => simp [hc] at h
            | ok v =>
              cases v <;> simp [hc] at h
              rename_i name
              split at h <;> try { simp at h }
              obtain ⟨ys, rfl⟩ := ih h
              exact ⟨x :: ys, rfl⟩
          | nil => exact fun _ => ⟨[], rfl⟩
          | _ => simp [«observation_list?/2», Lynx.Term.list]
        obtain ⟨xs, rfl⟩ := hlist objects hv
        have hil : Erlang.erlang.«is_list/1» (Lynx.Term.list xs) = .ok Lynx.Term.true := by
          cases xs <;> rfl
        have hsplit : Elixir.Enum.«split_with/2» d (Lynx.Term.list xs) (.function 5 1 #[worker]) =
            Elixir.Enum.«split_with/2» d (Lynx.Term.list xs) (.function 0 1 #[worker]) := by
          simp only [Elixir.Enum.«split_with/2», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, hil,
            Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true]
          rw [hfold]
        have hrev2 : ∀ (input : Lynx.Term) (tail : List Lynx.Term) (out : Lynx.Term),
            Erlang.lists.«reverse/2» input (Lynx.Term.list tail) = .ok out →
            ∃ ys, out = Lynx.Term.list ys := by
          intro input
          induction input using Lynx.Term.induct with
          | nil => intro tail out h; exact ⟨tail, (Except.ok.inj h).symm⟩
          | cons x xs hx ih => intro tail out h; exact ih (x :: tail) out h
          | _ => intros; simp_all [Erlang.lists.«reverse/2»]
        have hrev1 (input out : Lynx.Term) (h : Erlang.lists.«reverse/1» input = .ok out) :
            ∃ ys, out = Lynx.Term.list ys := by
          unfold Erlang.lists.«reverse/1» at h
          split at h
          · exact ⟨[], (Except.ok.inj h).symm⟩
          · rename_i x; exact ⟨[x], (Except.ok.inj h).symm⟩
          · rename_i a b; exact ⟨[b, a], (Except.ok.inj h).symm⟩
          · exact hrev2 _ _ _ h
          · contradiction
        have hshape (out : Lynx.Term)
            (h : Elixir.Enum.«split_with/2» d (Lynx.Term.list xs)
              (.function 0 1 #[worker]) = .ok out) :
            ∃ yes no, out = .tuple #[Lynx.Term.list yes, Lynx.Term.list no] := by
          simp only [Elixir.Enum.«split_with/2», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
            hil, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true] at h
          rw [Lynx.Except.bind_eq_ok] at h
          obtain ⟨acc, hacc, h⟩ := h
          split at h
          · rw [Lynx.Except.bind_eq_ok] at h
            obtain ⟨left, hl, h⟩ := h
            rw [Lynx.Except.bind_eq_ok] at h
            obtain ⟨right, hr, h⟩ := h
            obtain ⟨yes, rfl⟩ := hrev1 _ _ hl
            obtain ⟨no, rfl⟩ := hrev1 _ _ hr
            exact ⟨yes, no, (Except.ok.inj h).symm⟩
          · contradiction
        have happ (as bs : List Lynx.Term) :
            Erlang.erlang.«++/2» (Lynx.Term.list as) (Lynx.Term.list bs) =
              .ok (Lynx.Term.list (as ++ bs)) := by
          induction as <;> simp_all [Lynx.Term.list, Erlang.erlang.«++/2»]
        cases hs : Elixir.Enum.«split_with/2» d (Lynx.Term.list xs) (.function 0 1 #[worker]) with
        | error e => simp [«expected_cleanup/1», hkeys, d, hs] at hreq
        | ok out =>
          obtain ⟨yes, no, rfl⟩ := hshape out hs
          have hp := hsplit.trans hs
          simp only [Lynx.apply_eq, «production_cleanup_matches_spec:ensures/1»,
            Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind]
          cases yes with
          | nil =>
            cases no with
            | nil => simp [«expected_cleanup/1», hkeys, hs, d, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»] at hreq
            | cons n ns =>
              simp [Elixir.Ankole.AgentWorkers.Decision.«next/1», «expected_cleanup/1»,
                hkeys, hp, hs, d, Lynx.Term.list, Erlang.erlang.«==/2»,
                Erlang.erlang.«/=/2», Erlang.erlang.«=:=/2», Erlang.erlang.«hd/1», Std.ReflCmp.compare_self]
          | cons first extra =>
            cases extra with
            | nil =>
              cases no with
              | nil => simp [«expected_cleanup/1», hkeys, hs, d, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»] at hreq
              | cons n ns =>
                simp [Elixir.Ankole.AgentWorkers.Decision.«next/1», «expected_cleanup/1»,
                  hkeys, hp, hs, d, Lynx.Term.list, Erlang.erlang.«++/2»,
                  Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«=:=/2», Erlang.erlang.«hd/1»,
                  Std.ReflCmp.compare_self]
            | cons second rest =>
              simp [Elixir.Ankole.AgentWorkers.Decision.«next/1», «expected_cleanup/1»,
                hkeys, hp, hs, d, happ, Lynx.Term.list, Erlang.erlang.«++/2»,
                Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«=:=/2», Erlang.erlang.«hd/1»,
                Std.ReflCmp.compare_self]
      next => simp at hv
      """
    )
  end

  laws "ProviderKind and Decision reconciliation contracts" do
    cutoff(&:elixir_erl_pass.no_parens_remote/2)

    prelude(~LEAN"""
    module

    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare

    @[expose] public section

    namespace DecisionProof
    open Lynx

    @[simp] theorem compare_eq_atom (a : Term) (name : String) :
        (Term.compare a (.atom name) = .eq) ↔ a = .atom name := by
      cases a <;> rw [Term.compare_eq_step] <;> simp [Term.Compare.compareStep]

    @[simp] theorem atom_compare_eq (name : String) (a : Term) :
        (Term.compare (.atom name) a = .eq) ↔ a = .atom name := by
      rw [Std.OrientedCmp.eq_swap (cmp := Term.compare), Ordering.swap_eq_eq]
      exact compare_eq_atom a name

    theorem lookup_of_is_map_key {key : Term} {entries : List (Term × Term)}
        (h : Erlang.erlang.«is_map_key/2» key (.map entries) = .ok Term.true) :
        ∃ v, Term.getMapKeys [key] (.map entries) = [v] ∧
          Erlang.erlang.«map_get/2» key (.map entries) = .ok v := by
      simp only [Erlang.erlang.«is_map_key/2», Except.ok.injEq] at h
      have hany : (entries.any fun entry => Term.exactCompare key entry.1 == .eq) = true := by
        by_cases ha : (entries.any fun entry => Term.exactCompare key entry.1 == .eq) = true
        · exact ha
        · simp [ha, Term.true, Term.false] at h
      clear h
      simp only [Term.getMapKeys, Erlang.erlang.«map_get/2»]
      induction entries with
      | nil => simp at hany
      | cons hd tl ih =>
        by_cases heq : Term.exactCompare key hd.1 = .eq
        · refine ⟨hd.2, ?_, ?_⟩ <;>
            simp [List.find?, heq, Bind.bind, Pure.pure, Option.bind, Option.map]
        · have hbeq : (Term.exactCompare key hd.1 == .eq) = false := beq_false_of_ne heq
          simp only [List.any_cons, hbeq, Bool.false_or] at hany
          obtain ⟨v, hget, hmap⟩ := ih hany
          refine ⟨v, ?_, ?_⟩
          · simpa [List.find?, heq] using hget
          · simpa [List.find?, heq] using hmap

    end DecisionProof
    """)

    law(nil_generation_never_matches(worker, observation),
      requires:
        has_worker_observation_keys?(worker, observation) and
          is_nil(:erlang.map_get(:generation, worker)),
      expects: ProviderKind.current_instance?(worker, observation) == false,
      proof: ~LEAN"""
      rw [«nil_generation_never_matches:requires/2»] at requires
      rw [«nil_generation_never_matches:ensures/2»]
      have is_map_key_bool (k : Lynx.Term) (es : List (Lynx.Term × Lynx.Term)) :
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.true ∨
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.false := by
        simp only [Erlang.erlang.«is_map_key/2»]
        split <;> simp
      cases worker with
      | map wEntries =>
        rcases is_map_key_bool (.atom "generation") wEntries with hwgk | hwgk
        · rcases is_map_key_bool (.atom "instance_ref") wEntries with hwik | hwik
          · cases observation with
            | map oEntries =>
              rcases is_map_key_bool (.atom "generation") oEntries with hogk | hogk
              · rcases is_map_key_bool (.atom "instance_ref") oEntries with hoik | hoik
                · obtain ⟨wg, hwg_get, hwg_map⟩ := DecisionProof.lookup_of_is_map_key hwgk
                  have hwg_nil : wg = .atom "nil" := by
                    simp only [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                      hwgk, hwik, hogk, hoik, hwg_map, Erlang.erlang.«==/2»,
                      DecisionProof.compare_eq_atom, Lynx.Except.andAlso_eq,
                      Lynx.Except.ok_bind] at requires
                    by_cases hn : wg = .atom "nil"
                    · exact hn
                    · simp [hn, Lynx.Term.false] at requires
                  subst hwg_nil
                  simp [Elixir.Ankole.AgentWorkers.ProviderKind.«current_instance?/2», hwg_get,
                    Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«not/1»,
                    Std.ReflCmp.compare_self, Lynx.Term.true, Lynx.Term.false]
                · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                    hwgk, hwik, hogk, hoik, Lynx.Except.andAlso_eq] at requires
              · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                  hwgk, hwik, hogk, Lynx.Except.andAlso_eq] at requires
            | _ =>
              simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                hwgk, hwik, Lynx.Except.andAlso_eq] at requires
          · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
              hwgk, hwik, Lynx.Except.andAlso_eq] at requires
        · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
            hwgk, Lynx.Except.andAlso_eq] at requires
      | _ =>
        simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
          Lynx.Except.andAlso_eq] at requires
      """
    )

    law(current_instance_exact_spec(worker, observation),
      requires: has_worker_observation_keys?(worker, observation),
      expects:
        ProviderKind.current_instance?(worker, observation) ==
          expected_current_instance?(worker, observation),
      proof: ~LEAN"""
      rw [«current_instance_exact_spec:requires/2»] at requires
      rw [«current_instance_exact_spec:ensures/2»]
      have is_map_key_bool (k : Lynx.Term) (es : List (Lynx.Term × Lynx.Term)) :
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.true ∨
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.false := by
        simp only [Erlang.erlang.«is_map_key/2»]
        split <;> simp
      cases worker with
      | map wEntries =>
        rcases is_map_key_bool (.atom "generation") wEntries with hwgk | hwgk
        · rcases is_map_key_bool (.atom "instance_ref") wEntries with hwik | hwik
          · cases observation with
            | map oEntries =>
              rcases is_map_key_bool (.atom "generation") oEntries with hogk | hogk
              · rcases is_map_key_bool (.atom "instance_ref") oEntries with hoik | hoik
                · obtain ⟨wg, hwg_get, hwg_map⟩ := DecisionProof.lookup_of_is_map_key hwgk
                  obtain ⟨wi, hwi_get, hwi_map⟩ := DecisionProof.lookup_of_is_map_key hwik
                  obtain ⟨og, hog_get, hog_map⟩ := DecisionProof.lookup_of_is_map_key hogk
                  obtain ⟨oi, hoi_get, hoi_map⟩ := DecisionProof.lookup_of_is_map_key hoik
                  simp only [Elixir.Ankole.AgentWorkers.ProviderKind.«current_instance?/2»,
                    «expected_current_instance?/2», hwg_get, hwi_get, hog_get, hoi_get,
                    hwg_map, hwi_map, hog_map, hoi_map,
                    Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«not/1»,
                    DecisionProof.compare_eq_atom, Lynx.Except.andAlso_eq,
                    Lynx.Except.orElse_eq, Lynx.Except.ok_bind]
                  by_cases h1 : wg = .atom "nil" <;>
                    by_cases h2 : Lynx.Term.compare og wg = .eq <;>
                    by_cases h3 : wi = .atom "nil" <;>
                    by_cases h4 : Lynx.Term.compare oi wi = .eq <;>
                    simp [h1, h2, h3, h4, Std.ReflCmp.compare_self]
                · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                    hwgk, hwik, hogk, hoik, Lynx.Except.andAlso_eq] at requires
              · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                  hwgk, hwik, hogk, Lynx.Except.andAlso_eq] at requires
            | _ =>
              simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
                hwgk, hwik, Lynx.Except.andAlso_eq] at requires
          · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
              hwgk, hwik, Lynx.Except.andAlso_eq] at requires
        · simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
            hwgk, Lynx.Except.andAlso_eq] at requires
      | _ =>
        simp [«has_worker_observation_keys?/2», Erlang.erlang.«is_map/1»,
          Lynx.Except.andAlso_eq] at requires
      """
    )

    law(pause_release_exact_spec(definition, reason),
      requires: has_boolean_pause?(definition),
      expects:
        Decision.pause_release?(definition, reason) ==
          expected_pause_release?(definition, reason),
      proof: ~LEAN"""
      rw [«pause_release_exact_spec:requires/2»] at requires
      rw [«pause_release_exact_spec:ensures/2»]
      have is_map_key_bool (k : Lynx.Term) (es : List (Lynx.Term × Lynx.Term)) :
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.true ∨
          Erlang.erlang.«is_map_key/2» k (.map es) = .ok Lynx.Term.false := by
        simp only [Erlang.erlang.«is_map_key/2»]
        split <;> simp
      cases definition with
      | map dEntries =>
        rcases is_map_key_bool (.atom "pause") dEntries with hpk | hpk
        · obtain ⟨pv, hp_get, hp_map⟩ := DecisionProof.lookup_of_is_map_key hpk
          have hp_bool : pv = .atom "true" ∨ pv = .atom "false" := by
            simp only [«has_boolean_pause?/1», Erlang.erlang.«is_map/1», hpk, hp_map,
              Erlang.erlang.«is_boolean/1», Lynx.Except.andAlso_eq, Lynx.Except.ok_bind] at requires
            cases pv with
            | atom s =>
              by_cases ht : s = "true"
              · exact Or.inl (by subst ht; rfl)
              · by_cases hf : s = "false"
                · exact Or.inr (by subst hf; rfl)
                · simp [ht, hf] at requires
            | _ => simp at requires
          rcases hp_bool with rfl | rfl
          · simp only [Elixir.Ankole.AgentWorkers.Decision.«pause_release?/2»,
              «expected_pause_release?/2», hp_get, hp_map,
              Erlang.erlang.«==/2», Erlang.erlang.«=:=/2», DecisionProof.compare_eq_atom,
              Lynx.Term.isMember, Lynx.Except.andAlso_eq, Lynx.Except.orElse_eq,
              Lynx.Except.ok_bind]
            split <;> split <;> simp_all [Std.ReflCmp.compare_self, Lynx.Term.true, Lynx.Term.false]
          · simp [Elixir.Ankole.AgentWorkers.Decision.«pause_release?/2»,
              «expected_pause_release?/2», hp_get, hp_map,
              Erlang.erlang.«==/2», DecisionProof.compare_eq_atom,
              Lynx.Except.andAlso_eq, Lynx.Except.ok_bind, Std.ReflCmp.compare_self]
        · simp [«has_boolean_pause?/1», Erlang.erlang.«is_map/1», hpk,
            Lynx.Except.andAlso_eq] at requires
      | _ =>
        simp [«has_boolean_pause?/1», Erlang.erlang.«is_map/1»,
          Lynx.Except.andAlso_eq] at requires
      """
    )
  end

  describe "ProviderKind and Decision executable sanity checks" do
    test "production cleanup selects the second match or the first nonmatch" do
      first = %{generation: "g1", instance_ref: "pod-1"}
      second = %{generation: "g1", instance_ref: "pod-2"}
      third = %{generation: "g1", instance_ref: "pod-3"}
      stray = %{generation: "g0", instance_ref: "old-pod"}
      orphan = %{generation: nil, instance_ref: "orphan"}

      for state <- [:starting, :ready, :deleting],
          {instance_ref, objects, expected} <- [
            {nil, [first, second], second},
            {nil, [stray, first, second, third], second},
            {nil, [stray, orphan], stray},
            {nil, [first, stray], stray},
            {"pod-2", [first, second], first}
          ] do
        facts = %{
          worker: %{state: state, generation: "g1", instance_ref: instance_ref},
          objects: objects,
          agent: :active,
          turn_in_progress?: true
        }

        assert production_cleanup_matches_spec(facts)
        assert Decision.next(facts) == {:delete_object, expected}
      end

      for state <- [:absent, :deleting] do
        facts = %{
          worker: %{state: state, generation: nil, instance_ref: nil},
          objects: [orphan, first]
        }

        assert production_cleanup_matches_spec(facts)
        assert Decision.next(facts) == {:delete_object, orphan}
      end
    end

    test "nil generation never matches even when observation generation is nil" do
      for worker <- [
            %{generation: nil, instance_ref: nil},
            %{generation: nil, instance_ref: "pod-1"}
          ],
          observation <- [
            %{generation: nil, instance_ref: nil},
            %{generation: nil, instance_ref: "pod-1"},
            %{generation: "g1", instance_ref: "pod-1"}
          ] do
        assert nil_generation_never_matches(worker, observation)
        assert current_instance_exact_spec(worker, observation)
      end
    end

    test "pause_release? requires pause capability and idle or inactive drain reason" do
      for pause <- [true, false],
          reason <- [
            "idle_release",
            "agent_inactive",
            "replacement",
            "rebuild",
            "exited",
            "not_needed",
            nil
          ] do
        assert pause_release_exact_spec(%{pause: pause}, reason)
      end
    end
  end
end
