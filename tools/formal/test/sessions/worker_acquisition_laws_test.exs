defmodule Ankole.Formal.Sessions.WorkerAcquisitionLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Sessions.WorkerAcquisition

  defp idle_state?(:idle), do: true
  defp idle_state?({:idle, :requested}), do: true
  defp idle_state?(_), do: false

  defp idle_demand_event?(:idle, :request), do: true
  defp idle_demand_event?(:idle, :acquire), do: true
  defp idle_demand_event?({:idle, :requested}, :acquire), do: true
  defp idle_demand_event?(_state, _event), do: false

  defp workspace_reply?(:ready), do: true
  defp workspace_reply?({:waiting, _reason}), do: true
  defp workspace_reply?({:unavailable, _reason}), do: true
  defp workspace_reply?(_), do: false

  defp opening_with_worker?({:opening, _since, row}) when is_map(row), do: true
  defp opening_with_worker?(_), do: false

  defp in_flight_state?({:opening, since, _row}) when is_integer(since), do: true
  defp in_flight_state?({:waiting, _phase, since}) when is_integer(since), do: true
  defp in_flight_state?(_), do: false

  defp in_flight_since({:opening, since, _row}), do: since
  defp in_flight_since({:waiting, _phase, since}), do: since

  defp preserves_deadline?(since, {{:opening, next_since, _}, _effects}), do: next_since === since

  defp preserves_deadline?(since, {{:waiting, _phase, next_since}, _effects}),
    do: next_since === since

  defp preserves_deadline?(_since, {{:idle, :requested}, []}), do: true
  defp preserves_deadline?(_since, {{:ready, row}, [:ready]}) when is_map(row), do: true
  defp preserves_deadline?(_since, {{:unavailable, _reason}, _effects}), do: true
  defp preserves_deadline?(_since, _result), do: false

  defp expected_round_committed({:opening, _since, _row}), do: {{:idle, :requested}, []}
  defp expected_round_committed({:waiting, _phase, _since}), do: {{:idle, :requested}, []}
  defp expected_round_committed(state), do: {state, []}

  defp monotonic_in_flight?({:opening, since, _row}, now)
       when is_integer(since) and is_integer(now),
       do: now >= since

  defp monotonic_in_flight?({:waiting, _phase, since}, now)
       when is_integer(since) and is_integer(now),
       do: now >= since

  defp monotonic_in_flight?(_state, _now), do: false

  defp valid_in_flight_timers?(state, now, [{:acquire, acquire_ms}, {:check, check_ms}]) do
    {expired_state, _} = WorkerAcquisition.next(state, :expired, now)

    is_integer(acquire_ms) and acquire_ms >= 0 and acquire_ms <= 60_000 and
      acquire_ms == 0 == (expired_state != state) and
      check_ms in [5_000, 60_000]
  end

  defp valid_in_flight_timers?(_state, _now, _timers), do: false

  laws "WorkerAcquisition state machine contracts" do
    prelude(~LEAN"""
    module

    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare

    @[expose] public section

    namespace WorkerAcquisitionProof
    open Lynx

    @[simp] theorem compare_eq_atom (a : Term) (name : String) :
        (Term.compare a (.atom name) = .eq) ↔ a = .atom name := by
      cases a <;> rw [Term.compare_eq_step] <;> simp [Term.Compare.compareStep]

    @[simp] theorem atom_compare_eq (name : String) (a : Term) :
        (Term.compare (.atom name) a = .eq) ↔ a = .atom name := by
      rw [Std.OrientedCmp.eq_swap (cmp := Term.compare), Ordering.swap_eq_eq]
      exact compare_eq_atom a name

    @[simp] theorem exactCompare_atom (a : Term) (name : String) :
        (Term.exactCompare a (.atom name) = .eq) ↔ a = .atom name := by
      cases a <;> rw [Term.exactCompare_eq_step] <;> simp [Term.Compare.compareStep]

    @[simp] theorem atom_exactCompare (name : String) (a : Term) :
        (Term.exactCompare (.atom name) a = .eq) ↔ a = .atom name := by
      rw [Std.OrientedCmp.eq_swap (cmp := Term.exactCompare), Ordering.swap_eq_eq]
      exact exactCompare_atom a name

    @[simp] theorem exactCompare_integers (x y : Int) :
        (Term.exactCompare (.integer x) (.integer y) = .eq) ↔ x = y := by
      rw [Term.exactCompare_eq_step]
      simp [Term.Compare.compareStep, Int.compare_eq_eq]

    @[simp] theorem exactEq_integers (x y : Int) :
        Erlang.erlang.«=:=/2» (.integer x) (.integer y) =
          .ok (if x = y then Term.true else Term.false) := by
      simp [Erlang.erlang.«=:=/2», exactCompare_integers]

    @[simp] theorem exactCompare_tuple_size_neq (xs ys : List Term) (h : xs.length ≠ ys.length) :
        (Term.exactCompare (.tuple ⟨xs⟩) (.tuple ⟨ys⟩) = .eq) ↔ False := by
      rw [Term.exactCompare_eq_step]
      cases hlen : compare xs.length ys.length with
      | eq => exfalso; exact h (Nat.compare_eq_eq.mp hlen)
      | lt | gt => simp [Term.Compare.compareStep, hlen]

    @[simp] theorem compare_tuple_atom_neq (a1 a2 : String) (xs ys : List Term) (h : a1 ≠ a2) :
        (Term.compare (.tuple ⟨.atom a1 :: xs⟩) (.tuple ⟨.atom a2 :: ys⟩) = .eq) ↔ False := by
      rw [Term.compare_eq_step]
      simp only [Term.Compare.compareStep, Ordering.then_eq_eq, List.compareLex, iff_false]
      rintro ⟨_, hlex⟩
      cases hc : Term.compare (.atom a1) (.atom a2) <;> simp_all

    @[simp] theorem max_integers (x y : Int) :
        Erlang.erlang.«max/2» (.integer x) (.integer y) =
          .ok (.integer (if y ≤ x then x else y)) := by
      by_cases h : y ≤ x <;> simp [Erlang.erlang.«max/2», Int.isGE_compare, h]

    theorem clamped_remaining (s t : Int) :
        Erlang.erlang.«max/2» (.integer (60000 - (t - s))) (.integer 0) =
          .ok (.integer (if 60000 ≤ t - s then 0 else 60000 - (t - s))) := by
      rw [max_integers]
      congr 2
      split <;> split <;> omega

    @[simp] theorem eq_integers (x y : Int) :
        Erlang.erlang.«==/2» (.integer x) (.integer y) =
          .ok (if x = y then Term.true else Term.false) := by
      simp [Erlang.erlang.«==/2», Int.compare_eq_eq]

    @[simp] theorem eq_atom_self (name : String) :
        Erlang.erlang.«==/2» (.atom name) (.atom name) = .ok Term.true := by
      simp [Erlang.erlang.«==/2»]

    theorem eq_atom_of_ne {a : Term} {name : String} (h : a ≠ .atom name) :
        Erlang.erlang.«==/2» a (.atom name) = .ok Term.false := by
      simp [Erlang.erlang.«==/2», h]

    @[simp] theorem isMember_idle_3tuple (a b c : Term) :
        Term.isMember (.tuple ⟨[a, b, c]⟩)
          [.atom "idle", .tuple #[.atom "idle", .atom "requested"]] = Term.false := by
      have h1 : Term.exactCompare (.tuple ⟨[a, b, c]⟩) (.atom "idle") ≠ .eq := by simp
      have h2 : Term.exactCompare (.tuple ⟨[a, b, c]⟩)
          (.tuple ⟨[.atom "idle", .atom "requested"]⟩) ≠ .eq := by simp
      simp [Term.isMember,
        show #[Term.atom "idle", Term.atom "requested"] =
            ⟨[Term.atom "idle", Term.atom "requested"]⟩ from rfl,
        h1, h2]

    end WorkerAcquisitionProof
    """)

    termination_suffix(
      &WorkerAcquisition.error_text/1,
      ~LEAN"""
      termination_by match _0 with
        | Lynx.Term.atom "worker_provider_missing" => (0 : Nat)
        | _ => 1
      decreasing_by decide
      """
    )

    termination_suffix(
      &WorkerAcquisition.next/3,
      ~LEAN"""
      termination_by match _1 with
        | Lynx.Term.atom "acquire" => (0 : Nat)
        | _ => 1
      decreasing_by decide
      """
    )

    law(unavailable_is_absorbing(reason, event, now),
      expects:
        WorkerAcquisition.next({:unavailable, reason}, event, now) ==
          {{:unavailable, reason}, []},
      proof: ~LEAN"""
      rw [«unavailable_is_absorbing:ensures/3»]
      simp [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def,
        Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      """
    )

    law(idle_ignores_non_demand_events(state, event, now),
      requires: idle_state?(state) and not idle_demand_event?(state, event),
      expects: WorkerAcquisition.next(state, event, now) == {state, []},
      proof: ~LEAN"""
      rw [«idle_ignores_non_demand_events:requires/3»] at requires
      rw [«idle_ignores_non_demand_events:ensures/3»]
      have hidle : state = .atom "idle" ∨ state = .tuple #[.atom "idle", .atom "requested"] := by
        cases state with
        | atom s =>
          by_cases hs : s = "idle"
          · exact Or.inl (by subst hs; rfl)
          · simp [«idle_state?/1», hs] at requires
        | tuple elems =>
          rcases elems with ⟨l⟩
          match l with
          | [] | [_] | [_, _, _] | _ :: _ :: _ :: _ :: _ =>
            simp [«idle_state?/1»] at requires
          | [a, b] =>
            by_cases ha : a = .atom "idle"
            · subst ha
              by_cases hb : b = .atom "requested"
              · subst hb; exact Or.inr rfl
              · simp [«idle_state?/1», hb] at requires
            · simp [«idle_state?/1», ha] at requires
        | _ => simp [«idle_state?/1»] at requires
      have hstep : Elixir.Ankole.Sessions.WorkerAcquisition.«next/3» state event now =
          .ok (.tuple #[state, .nil]) := by
        rcases hidle with rfl | rfl
        · have hreq : event ≠ .atom "request" := by
            rintro rfl; simp [«idle_state?/1», «idle_demand_event?/2», Erlang.erlang.«not/1»] at requires
          have hacq : event ≠ .atom "acquire" := by
            rintro rfl; simp [«idle_state?/1», «idle_demand_event?/2», Erlang.erlang.«not/1»] at requires
          rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
          split
          · contradiction
          · contradiction
          · dsimp only []
            split
            · contradiction
            · split <;> solve
                | rfl
                | contradiction
                | (split <;> solve | rfl | contradiction)
        · have hacq : event ≠ .atom "acquire" := by
            rintro rfl; simp [«idle_state?/1», «idle_demand_event?/2», Erlang.erlang.«not/1»] at requires
          rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
          split
          · rename_i heq; simp at heq
          · contradiction
          · dsimp only []
            split
            · contradiction
            · split <;> solve
                | rfl
                | contradiction
                | (exfalso; simp_all)
                | (split <;> solve | rfl | (exfalso; simp_all))
      simp [hstep, Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      """
    )

    law(workspace_replies_require_opening_worker(state, reply, now),
      requires: workspace_reply?(reply) and not opening_with_worker?(state),
      expects: WorkerAcquisition.next(state, reply, now) == {state, []},
      proof: ~LEAN"""
      rw [«workspace_replies_require_opening_worker:requires/3»] at requires
      rw [«workspace_replies_require_opening_worker:ensures/3»]
      have hreply :
          reply = .atom "ready" ∨
          (∃ r, reply = .tuple #[.atom "waiting", r]) ∨
          (∃ r, reply = .tuple #[.atom "unavailable", r]) := by
        cases reply with
        | atom s =>
          by_cases hs : s = "ready"
          · exact Or.inl (by subst hs; rfl)
          · simp [«workspace_reply?/1», hs] at requires
        | tuple elems =>
          rcases elems with ⟨l⟩
          match l with
          | [] | [_] | _ :: _ :: _ :: _ =>
            simp [«workspace_reply?/1»] at requires
          | [a, r] =>
            by_cases hw : a = .atom "waiting"
            · exact Or.inr (Or.inl ⟨r, by subst hw; rfl⟩)
            · by_cases hu : a = .atom "unavailable"
              · exact Or.inr (Or.inr ⟨r, by subst hu; rfl⟩)
              · simp [«workspace_reply?/1», hw, hu] at requires
        | _ => simp [«workspace_reply?/1»] at requires
      have hnot_open : ∀ since entries, state ≠ .tuple #[.atom "opening", since, .map entries] := by
        intro since entries hst
        subst hst
        rcases hreply with rfl | ⟨r, rfl⟩ | ⟨r, rfl⟩ <;>
          simp [«workspace_reply?/1», «opening_with_worker?/1», Erlang.erlang.«not/1»] at requires
      have hstep : Elixir.Ankole.Sessions.WorkerAcquisition.«next/3» state reply now =
          .ok (.tuple #[state, .nil]) := by
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        split
        · rfl
        · exfalso; rcases hreply with h | ⟨_, h⟩ | ⟨_, h⟩ <;> simp at h
        · dsimp only []
          split
          · exfalso; rcases hreply with h | ⟨_, h⟩ | ⟨_, h⟩ <;> simp at h
          · split <;> solve
              | rfl
              | (exfalso; exact hnot_open _ _ rfl)
              | (exfalso; rcases hreply with h | ⟨_, h⟩ | ⟨_, h⟩ <;> simp at h)
      simp [hstep, Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      """
    )

    law(round_committed_clears_only_in_flight(state, now),
      expects:
        WorkerAcquisition.next(state, :round_committed, now) ==
          expected_round_committed(state),
      proof: ~LEAN"""
      rw [«round_committed_clears_only_in_flight:ensures/2»]
      unfold «expected_round_committed/1»
      split
      · rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        simp [Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      · rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        simp [Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      · rename_i h_not_open h_not_wait
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        split
        · simp [Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
        · exfalso; simp at *
        · dsimp only []
          split
          · exfalso; simp at *
          · split <;> solve
              | simp [Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
              | (exfalso; exact h_not_open _ _ rfl)
              | (exfalso; exact h_not_wait _ _ rfl)
              | (exfalso; simp at *)
      """
    )

    law(deadline_preserved_across_retries(state, event, now),
      requires: in_flight_state?(state) and is_integer(now),
      expects:
        preserves_deadline?(
          in_flight_since(state),
          WorkerAcquisition.next(state, event, now)
        ),
      proof: ~LEAN"""
      rw [«deadline_preserved_across_retries:requires/3»] at requires
      rw [«deadline_preserved_across_retries:ensures/3»]
      have hstate :
          (∃ s t : Int, ∃ row : Lynx.Term,
            state = .tuple ⟨[.atom "opening", .integer s, row]⟩ ∧ now = .integer t) ∨
          (∃ phase : Lynx.Term, ∃ s t : Int,
            state = .tuple ⟨[.atom "waiting", phase, .integer s]⟩ ∧ now = .integer t) := by
        cases state with
        | tuple elems =>
          rcases elems with ⟨l⟩
          match l with
          | [] | [_] | [_, _] | _ :: _ :: _ :: _ :: _ =>
            simp [«in_flight_state?/1»] at requires
          | [a, b, c] =>
            by_cases ho : a = .atom "opening"
            · subst ho
              cases b with
              | integer s =>
                cases now with
                | integer t => exact Or.inl ⟨s, t, c, rfl, rfl⟩
                | _ => simp [«in_flight_state?/1», Erlang.erlang.«is_integer/1»] at requires
              | _ => simp [«in_flight_state?/1»] at requires
            · by_cases hw : a = .atom "waiting"
              · subst hw
                cases c with
                | integer s =>
                  cases now with
                  | integer t => exact Or.inr ⟨b, s, t, rfl, rfl⟩
                  | _ => simp [«in_flight_state?/1», Erlang.erlang.«is_integer/1»] at requires
                | _ => simp [«in_flight_state?/1»] at requires
              · simp [«in_flight_state?/1», ho, hw] at requires
        | _ => simp [«in_flight_state?/1»] at requires
      clear requires
      rcases hstate with ⟨s, t, row, rfl, rfl⟩ | ⟨phase, s, t, rfl, rfl⟩
      all_goals
        simp only [«in_flight_since/1», Lynx.Except.ok_bind]
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        split
        · exfalso; simp at *
        · exfalso; simp at *
        · dsimp only []
          split
          · simp only [WorkerAcquisitionProof.isMember_idle_3tuple, Lynx.Except.guard]
            simp [«preserves_deadline?/2»]
          · split <;> solve
              | (injections; (try injections); done)
              | ((try injections); (try injections); (try subst_vars); simp [«preserves_deadline?/2»])
              | ((try injections); (try injections); (try subst_vars); exfalso; simp at *)
              | ((try injections); (try injections); (try subst_vars)
                 simp [Erlang.erlang.«==/2»]
                 split
                 · simp [«preserves_deadline?/2»]
                 · simp [«preserves_deadline?/2»]
                 · exfalso; split at * <;> simp_all [Lynx.Term.true, Lynx.Term.false])
              | ((try injections); (try injections); (try subst_vars)
                 simp [Elixir.Ankole.Sessions.WorkerAcquisition.«unavailable/1»]
                 split
                 · simp [«preserves_deadline?/2»]
                 · simp [«preserves_deadline?/2»]
                 · exfalso; split at * <;> simp_all [Lynx.Term.true, Lynx.Term.false])
              | ((try injections); (try injections); (try subst_vars)
                 rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
                 simp [«preserves_deadline?/2», WorkerAcquisitionProof.isMember_idle_3tuple,
                   Lynx.Except.guard])
              | (split <;> solve
                  | (injections; (try injections); done)
                  | ((try injections); (try injections); exfalso; simp at *)
                  | simp [«preserves_deadline?/2»])
      """
    )

    law(timers_consistent_with_expiry(state, now),
      requires: monotonic_in_flight?(state, now),
      expects: valid_in_flight_timers?(state, now, WorkerAcquisition.timers(state, now)),
      proof: ~LEAN"""
      rw [«timers_consistent_with_expiry:requires/2»] at requires
      rw [«timers_consistent_with_expiry:ensures/2»]
      have hstate :
          (∃ s t : Int, ∃ row : Lynx.Term,
            state = .tuple #[.atom "opening", .integer s, row] ∧ now = .integer t ∧ s ≤ t) ∨
          (∃ phase : Lynx.Term, ∃ s t : Int,
            state = .tuple #[.atom "waiting", phase, .integer s] ∧ now = .integer t ∧ s ≤ t) := by
        cases state with
        | tuple elems =>
          rcases elems with ⟨l⟩
          match l with
          | [] | [_] | [_, _] | _ :: _ :: _ :: _ :: _ =>
            simp [«monotonic_in_flight?/2», Lynx.Except.guard] at requires
          | [a, b, c] =>
            by_cases ho : a = .atom "opening"
            · subst ho
              cases b with
              | integer s =>
                cases now with
                | integer t =>
                  simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                    Erlang.erlang.«>=/2_integers», Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
                  exact Or.inl ⟨s, t, c, rfl, rfl, requires⟩
                | _ =>
                  simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                    Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
              | _ =>
                simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                  Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
            · by_cases hw : a = .atom "waiting"
              · subst hw
                cases c with
                | integer s =>
                  cases now with
                  | integer t =>
                    simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                      Erlang.erlang.«>=/2_integers», Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
                    exact Or.inr ⟨b, s, t, rfl, rfl, requires⟩
                  | _ =>
                    simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                      Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
                | _ =>
                  simp [«monotonic_in_flight?/2», Erlang.erlang.«is_integer/1»,
                    Lynx.Except.guard, Lynx.Except.andAlso_eq] at requires
              · simp [«monotonic_in_flight?/2», ho, hw, Lynx.Except.guard] at requires
        | _ =>
          simp [«monotonic_in_flight?/2», Lynx.Except.guard] at requires
      rcases hstate with ⟨s, t, row, rfl, rfl, hle⟩ | ⟨phase, s, t, rfl, rfl, hle⟩
      · simp only [Elixir.Ankole.Sessions.WorkerAcquisition.«timers/2»,
          Erlang.erlang.«-/2_integers», WorkerAcquisitionProof.clamped_remaining,
          Lynx.Except.ok_bind, «valid_in_flight_timers?/3»]
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
        simp only [Erlang.erlang.«-/2_integers», Erlang.erlang.«>=/2_integers»,
          Elixir.Ankole.Sessions.WorkerAcquisition.«unavailable/1», Lynx.Except.ok_bind]
        by_cases hexp : 60000 ≤ t - s
        · simp [hexp, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Erlang.erlang.«=</2_integers», Erlang.erlang.«/=/2», Erlang.erlang.«==/2»,
            Lynx.Term.isMember]
        · have hts : t - s ≤ 60000 := by omega
          have hle60 : 60000 - (t - s) ≤ 60000 := by omega
          have hnz : 60000 - (t - s) ≠ 0 := by omega
          simp [hexp, hts, hle60, hnz, Erlang.erlang.«is_integer/1»,
            Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
            Erlang.erlang.«/=/2», Erlang.erlang.«==/2», Std.ReflCmp.compare_self,
            Lynx.Term.isMember]
      · by_cases hp : phase = .atom "retrying"
        · subst hp
          simp only [Elixir.Ankole.Sessions.WorkerAcquisition.«timers/2»,
            Erlang.erlang.«-/2_integers», WorkerAcquisitionProof.clamped_remaining,
            WorkerAcquisitionProof.eq_atom_self, Lynx.Except.ok_bind,
            «valid_in_flight_timers?/3»]
          rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
          simp only [Erlang.erlang.«-/2_integers», Erlang.erlang.«>=/2_integers»,
            Elixir.Ankole.Sessions.WorkerAcquisition.«unavailable/1», Lynx.Except.ok_bind]
          by_cases hexp : 60000 ≤ t - s
          · simp [hexp, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
              Erlang.erlang.«=</2_integers», Erlang.erlang.«/=/2», Erlang.erlang.«==/2»,
              Lynx.Term.isMember]
          · have hts : t - s ≤ 60000 := by omega
            have hle60 : 60000 - (t - s) ≤ 60000 := by omega
            have hnz : 60000 - (t - s) ≠ 0 := by omega
            simp [hexp, hts, hle60, hnz, Erlang.erlang.«is_integer/1»,
              Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
              Erlang.erlang.«/=/2», Erlang.erlang.«==/2», Std.ReflCmp.compare_self,
              Lynx.Term.isMember]
        · simp only [Elixir.Ankole.Sessions.WorkerAcquisition.«timers/2»,
            Erlang.erlang.«-/2_integers», WorkerAcquisitionProof.clamped_remaining,
            WorkerAcquisitionProof.eq_atom_of_ne hp, Lynx.Except.ok_bind,
            «valid_in_flight_timers?/3»]
          rw [Elixir.Ankole.Sessions.WorkerAcquisition.«next/3».eq_def]
          simp only [Erlang.erlang.«-/2_integers», Erlang.erlang.«>=/2_integers»,
            Elixir.Ankole.Sessions.WorkerAcquisition.«unavailable/1», Lynx.Except.ok_bind]
          by_cases hexp : 60000 ≤ t - s
          · simp [hexp, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
              Erlang.erlang.«=</2_integers», Erlang.erlang.«/=/2», Erlang.erlang.«==/2»,
              Lynx.Term.isMember]
          · have hts : t - s ≤ 60000 := by omega
            have hle60 : 60000 - (t - s) ≤ 60000 := by omega
            have hnz : 60000 - (t - s) ≠ 0 := by omega
            simp [hexp, hts, hle60, hnz, Erlang.erlang.«is_integer/1»,
              Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
              Erlang.erlang.«/=/2», Erlang.erlang.«==/2», Std.ReflCmp.compare_self,
              Lynx.Term.isMember]
      """
    )

    law(rejected_error_text_redacts_detail(detail),
      expects:
        WorkerAcquisition.error_text({:rejected, detail}) ==
          WorkerAcquisition.error_text(:worker_provider_missing) and
          is_binary(WorkerAcquisition.error_text(detail)),
      proof: ~LEAN"""
      rw [«rejected_error_text_redacts_detail:ensures/1»]
      have hbin : Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_kizgp2hn) = .ok Lynx.Term.true ∧
          Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_liheonu6) = .ok Lynx.Term.true ∧
          Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_doiv3vgt) = .ok Lynx.Term.true ∧
          Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_6df2lgqz) = .ok Lynx.Term.true ∧
          Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_b7l46356) = .ok Lynx.Term.true ∧
          Erlang.erlang.«is_binary/1» (Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_eadvwwvi) = .ok Lynx.Term.true :=
        ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩
      have htot : ∃ out, Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1» detail = .ok out ∧
          Erlang.erlang.«is_binary/1» out = .ok Lynx.Term.true := by
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1».eq_def]
        split
        · rw [Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1».eq_def]
          exact ⟨_, rfl, hbin.1⟩
        · exact ⟨_, rfl, hbin.1⟩
        · exact ⟨_, rfl, hbin.2.1⟩
        · exact ⟨_, rfl, hbin.2.2.1⟩
        · exact ⟨_, rfl, hbin.2.2.2.1⟩
        · exact ⟨_, rfl, hbin.2.2.2.2.1⟩
        · exact ⟨_, rfl, hbin.2.2.2.2.2⟩
      obtain ⟨out, hout, hbout⟩ := htot
      have hrej : Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1»
          (.tuple #[.atom "rejected", detail]) =
          Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1» (.atom "worker_provider_missing") := by
        conv => lhs; rw [Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1».eq_def]
        rfl
      have hwpm : Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1»
          (.atom "worker_provider_missing") =
          .ok Elixir.Ankole.Sessions.WorkerAcquisition.lynx_literal_kizgp2hn := by
        rw [Elixir.Ankole.Sessions.WorkerAcquisition.«error_text/1».eq_def]
        rfl
      simp [hrej, hwpm, hout, hbout, Erlang.erlang.«==/2», Std.ReflCmp.compare_self]
      """
    )
  end

  describe "WorkerAcquisition executable sanity checks" do
    test "workspace replies are ignored outside {:opening, since, worker_map}" do
      worker = %{agent_uid: "agt_1", generation: "g1"}

      for state <- [
            :idle,
            {:idle, :requested},
            {:opening, 100, nil},
            {:waiting, :capacity, 100},
            {:ready, worker},
            {:unavailable, :agent_not_active}
          ],
          reply <- [:ready, {:waiting, :CAPACITY}, {:waiting, :DRAINING}, {:unavailable, :closed}] do
        assert workspace_replies_require_opening_worker(state, reply, 250)
      end
    end

    test "deadline anchor and timer consistency hold across in-flight states" do
      worker = %{agent_uid: "agt_1", generation: "g1"}

      for state <- [
            {:opening, 1_000, nil},
            {:opening, 1_000, worker},
            {:waiting, :starting, 1_000},
            {:waiting, :retrying, 1_000}
          ],
          now <- [1_000, 35_000, 61_000, 120_000] do
        assert timers_consistent_with_expiry(state, now)

        for event <- [
              :acquire,
              :check,
              :expired,
              :round_committed,
              :send_failed,
              {:resolved, {:wait, :retrying}},
              {:checked, {:ok, :changed}},
              {:waiting, :CAPACITY}
            ] do
          assert deadline_preserved_across_retries(state, event, now)
        end
      end
    end
  end
end
