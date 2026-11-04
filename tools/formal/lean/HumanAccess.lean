module
public import Std
@[expose] public section
namespace Ankole.HumanAccess

structure Restriction where
  offboard : Bool
  cleared : Option Nat
  deriving DecidableEq
structure Access where
  active : Bool
  version : Nat
  restore : Option Nat
  restrictions : List Restriction
  release : Nat
  deriving DecidableEq

inductive Change where | suspend | offboard | restore
  deriving DecidableEq

def change (s : Access) (event : Change) (now : Nat) : Access :=
  match event with
  | .suspend => {s with active := false, version := s.version + if s.active then 1 else 0, restrictions := ⟨false, none⟩ :: s.restrictions}
  | .offboard => {s with active := false, version := s.version + if s.active then 1 else 0, restrictions := ⟨true, none⟩ :: s.restrictions, release := max s.release now}
  | .restore => {s with active := true, restore := some now, restrictions := s.restrictions.map (fun r => if r.cleared.isNone then {r with cleared := some now} else r)}

def inCycle (restored : Option Nat) (r : Restriction) : Prop :=
  r.offboard = true ∧ match restored, r.cleared with
  | none, _ | _, none => True
  | some t, some cleared => t < cleared

def departed (s : Access) : Prop :=
  s.active = false ∧ ∃ r ∈ s.restrictions, inCycle s.restore r

theorem suspend_keeps_departure (s : Access) (now : Nat) (disabled : s.active = false) :
    departed (change s .suspend now) ↔ departed s := by
  simp [departed, change, inCycle, disabled]

theorem offboard_records_departure (s : Access) (now : Nat) :
    departed (change s .offboard now) := by
  refine ⟨rfl, ⟨true, none⟩, by simp [change], ?_⟩
  cases h : s.restore <;> simp [inCycle, change, h]

theorem restore_ends_disabled_cycle (s : Access) (now : Nat) :
    ¬ departed (change s .restore now) := by simp [departed, change]

theorem offboard_releases_disabled (s : Access) (now : Nat) :
    now ≤ (change s .offboard now).release := Nat.le_max_right _ _

theorem revoking_active_access_invalidates_old_version (s : Access) (e : Change) (now : Nat)
    (active : s.active = true) (revoke : e ≠ .restore) :
    (change s e now).version = s.version + 1 := by cases e <;> simp_all [change]

theorem disabled_cycle_keeps_version (s : Access) (e : Change) (now : Nat)
    (disabled : s.active = false) :
    (change s e now).version = s.version := by cases e <;> simp [change, disabled]

theorem restoration_keeps_version (s : Access) (now : Nat) :
    (change s .restore now).version = s.version := rfl

theorem change_never_decreases_version (s : Access) (e : Change) (now : Nat) :
    s.version ≤ (change s e now).version := by
  cases active : s.active <;> cases e <;> simp [change, active]

def applyChanges (s : Access) : List (Change × Nat) → Access
  | [] => s
  | (event, now) :: rest => applyChanges (change s event now) rest

theorem trace_never_decreases_version (s : Access) (events : List (Change × Nat)) :
    s.version ≤ (applyChanges s events).version := by
  induction events generalizing s with
  | nil => exact Nat.le_refl _
  | cons event rest ih =>
    exact Nat.le_trans (change_never_decreases_version s event.1 event.2) (ih _)

theorem revoked_version_never_returns (s : Access) (events : List (Change × Nat))
    (captured : Nat) (revoked : captured < s.version) :
    captured < (applyChanges s events).version := by
  have monotone := trace_never_decreases_version s events
  omega

-- One disabled cycle revokes once. Restoring membership permits fresh work
-- under the new version without reviving work captured before revocation.
example : (applyChanges ⟨true, 5, none, [], 0⟩
    [(.suspend, 1), (.offboard, 2), (.restore, 3)]).version = 6 := rfl

def claimCurrent (release started : Nat) := release < started

theorem pre_release_challenge_rejected {release started : Nat} (h : started ≤ release) :
    ¬ claimCurrent release started := Nat.not_lt.mpr h

-- Consumption commits before account completion. Completion failure is not rollback.
structure OTP where
  consumed : Bool
  attempts : Nat
  deriving DecidableEq
inductive Event where | attempt (correct : Bool) (live : Bool) | completionFailure
  deriving DecidableEq

def step (limit : Nat) (s : OTP) (e : Event) : OTP × Bool :=
  match e with
  | .completionFailure => (s, false)
  | .attempt correct live =>
    if s.consumed || !live || decide (limit ≤ s.attempts) then (s, false)
    else ({consumed := correct, attempts := s.attempts + if correct then 0 else 1}, correct)

theorem consumed_absorbs (limit : Nat) (s : OTP) (e : Event) (h : s.consumed = true) :
    step limit s e = (s, false) := by cases e <;> simp [step, h]

theorem exhaustion_absorbs (limit : Nat) (s : OTP) (e : Event) (h : limit ≤ s.attempts) :
    step limit s e = (s, false) := by cases e <;> simp [step, h]

theorem accepted_consumes (limit : Nat) (s : OTP) (e : Event)
    (h : (step limit s e).2 = true) : (step limit s e).1.consumed = true := by
  cases e <;> simp only [step] at *
  · split at h <;> simp_all [Nat.not_le.mpr]
  · simp at h

def run (limit : Nat) (s : OTP) : List Event → OTP × Nat
  | [] => (s, 0)
  | e :: rest =>
    let (next, accepted) := step limit s e
    let (final, count) := run limit next rest
    (final, count + if accepted then 1 else 0)

theorem consumed_never_accepts (limit : Nat) (s : OTP) (events : List Event)
    (h : s.consumed = true) : run limit s events = (s, 0) := by
  induction events with
  | nil => rfl
  | cons e rest ih => simp [run, consumed_absorbs limit s e h, ih]

theorem at_most_once (limit : Nat) (s : OTP) (events : List Event) :
    (run limit s events).2 ≤ 1 := by
  induction events generalizing s with
  | nil => simp [run]
  | cons e rest ih =>
    cases h : (step limit s e).2
    · simpa [run, h] using ih (step limit s e).1
    · have consumed := accepted_consumes limit s e h
      simp [run, h, consumed_never_accepts limit (step limit s e).1 rest consumed]

example : step 5 {consumed := true, attempts := 1} .completionFailure =
    ({consumed := true, attempts := 1}, false) := rfl
end Ankole.HumanAccess
