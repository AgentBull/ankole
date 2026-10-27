module
public import Std
@[expose] public section
namespace Ankole.AppletLifecycle

inductive Outcome where | completed (value : Nat) | cancelled | failed
  deriving DecidableEq
inductive Phase where | admitting | running | terminal (result : Outcome)
  deriving DecidableEq
structure State where
  phase : Phase
  starts : Nat
  retries : Nat
  deadline : Int
  writes : Nat
  deriving DecidableEq
inductive Event where
  | retryableFailure | start (now : Int) | done (value : Nat)
  | disconnect | cancel | capabilityCommit | foreignRun | cleanupFailure
  deriving DecidableEq

def step (s : State) (e : Event) : State :=
  match s.phase with
  | .terminal _ => s
  | .admitting => match e with
    | .retryableFailure => if s.retries = 0 then {s with retries := 1}
        else {s with phase := .terminal .failed}
    | .start now => if now < s.deadline then {s with phase := .running, starts := s.starts + 1}
        else {s with phase := .terminal .failed}
    | .cancel => {s with phase := .terminal .cancelled}
    | .disconnect | .cleanupFailure => {s with phase := .terminal .failed}
    | _ => s
  | .running => match e with
    | .done value => {s with phase := .terminal (.completed value)}
    | .cancel => {s with phase := .terminal .cancelled}
    | .disconnect | .retryableFailure | .cleanupFailure => {s with phase := .terminal .failed}
    | .capabilityCommit => {s with writes := s.writes + 1}
    | _ => s

def invariant (s : State) := s.starts ≤ 1 ∧ s.retries ≤ 1 ∧ (s.phase = .admitting → s.starts = 0)

theorem step_preserves (s : State) (e : Event) (h : invariant s) : invariant (step s e) := by
  rcases h with ⟨hs, hr, ha⟩
  unfold step
  cases hp : s.phase <;> cases e <;> dsimp only <;> simp_all [invariant] <;> split <;> simp_all <;> omega

def run (s : State) : List Event → State
  | [] => s
  | e :: rest => run (step s e) rest

theorem trace_at_most_one_start (s : State) (events : List Event) (h : invariant s) :
    (run s events).starts ≤ 1 := by
  induction events generalizing s with
  | nil => exact h.1
  | cons e rest ih => exact ih _ (step_preserves s e h)

theorem deadline_is_shared (s : State) (e : Event) : (step s e).deadline = s.deadline := by
  unfold step
  cases hp : s.phase <;> cases e <;> dsimp only <;> try rfl
  all_goals split <;> rfl

theorem terminal_survives_cleanup_and_late_frames (s : State) (outcome : Outcome) (e : Event)
    (h : s.phase = .terminal outcome) : step s e = s := by
  unfold step
  rw [h]

theorem cancellation_does_not_undo_commits (s : State) : (step s .cancel).writes = s.writes := by
  unfold step
  cases hp : s.phase <;> rfl

theorem other_run_is_ignored (s : State) : step s .foreignRun = s := by
  unfold step
  cases hp : s.phase <;> rfl

-- A failed transport after a capability commit retains the write and is terminal.
example :
    step (step ⟨.running, 1, 0, 100, 0⟩ .capabilityCommit) .disconnect =
      ⟨.terminal .failed, 1, 0, 100, 1⟩ := rfl
end Ankole.AppletLifecycle
