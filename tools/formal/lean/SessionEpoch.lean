module

public import Std

@[expose] public section

/-
The Session workspace epoch fence.

`Ankole.Sessions.Fence` serializes Driver writes with admission. Admission
advances the workspace epoch; a run may commit only while its epoch still
matches the workspace. `Ankole.Sessions.Run.refund_in_tx/2` is the deliberate
exception: a stale Driver gives back the attempt it consumed.

The model abstracts the workspace row, the incoming Signal counters, and one
run. It records that the refund path has no attempt identity: the refund
decrements whichever attempt is live, so two stale writers can credit twice.
-/

namespace Ankole.SessionEpoch

structure Workspace where
  epoch : Nat
  deriving Repr, DecidableEq

structure Signal where
  attempts : Nat
  capacityAttempts : Nat
  live : Bool
  deriving Repr, DecidableEq

structure Run where
  epoch : Nat
  attempts : Nat
  deriving Repr, DecidableEq

def admit (w : Workspace) (s : Signal) : Workspace × Signal :=
  ({ epoch := w.epoch + 1 },
   { s with attempts := s.attempts + 1, live := true })

/- A writer may commit only against its own epoch. -/
def commitAllowed (w : Workspace) (r : Run) : Prop := w.epoch = r.epoch

instance (w : Workspace) (r : Run) : Decidable (commitAllowed w r) := by
  unfold commitAllowed
  infer_instance

/-- A stale Driver refunds one attempt against the live Signal row. The
condition intentionally does not compare the run's attempt with the live
attempt count. -/
def refund (w : Workspace) (s : Signal) (r : Run) : Signal :=
  if w.epoch > r.epoch ∧ s.live then
    { s with attempts := if s.capacityAttempts < s.attempts then s.attempts - 1 else s.attempts }
  else s

theorem admit_bumps_epoch (w : Workspace) (s : Signal) :
    (admit w s).1.epoch = w.epoch + 1 := rfl

theorem admit_charges_attempt (w : Workspace) (s : Signal) :
    (admit w s).2.attempts = s.attempts + 1 := rfl

theorem stale_commit_rejected (w : Workspace) (r : Run) (h : r.epoch < w.epoch) :
    ¬ commitAllowed w r := by
  unfold commitAllowed
  omega

theorem current_commit_allowed (w : Workspace) (r : Run) (h : r.epoch = w.epoch) :
    commitAllowed w r := h.symm

/-- The refund path accepts any run from an older epoch, even one whose
attempt was already replaced by a newer admission. -/
theorem stale_refund_allowed (w : Workspace) (s : Signal) (r : Run)
    (hstale : r.epoch < w.epoch) (hlive : s.live = true) :
    (refund w s r).attempts = (if s.capacityAttempts < s.attempts then s.attempts - 1 else s.attempts) := by
  simp [refund, hstale, hlive]

theorem refund_stale_decrements (w : Workspace) (s : Signal) (r : Run)
    (hstale : r.epoch < w.epoch) (hlive : s.live = true) (hcount : s.capacityAttempts < s.attempts) :
    (refund w s r).attempts = s.attempts - 1 := by
  simp [refund, hstale, hlive, hcount]

theorem refund_never_negative (w : Workspace) (s : Signal) (r : Run) :
    (refund w s r).attempts ≤ s.attempts := by
  by_cases h : w.epoch > r.epoch ∧ s.live
  · simp [refund, h]
    split <;> omega
  · simp [refund, h]

/-- The refund decision does not inspect the run's attempt: any stale run can
claim the live attempt's credit. -/
theorem refund_ignores_run_attempt (w : Workspace) (s : Signal) (r : Run) (attempt : Nat) :
    refund w s { r with attempts := attempt } = refund w s r := rfl

/-- Two stale writers for the same live Signal each refund one attempt. -/
theorem double_refund_credits_twice (w : Workspace) (s : Signal) (r : Run)
    (hstale : r.epoch < w.epoch) (hlive : s.live = true)
    (hfirst : s.capacityAttempts < s.attempts)
    (hsecond : s.capacityAttempts + 1 < s.attempts) :
    (refund w (refund w s r) r).attempts = s.attempts - 2 := by
  have h1 := refund_stale_decrements w s r hstale hlive hfirst
  have hlive' : (refund w s r).live = true := by simp [refund, hstale, hlive]
  have hcap : (refund w s r).capacityAttempts < (refund w s r).attempts := by
    rw [h1]
    simp [refund, hstale, hlive]
    omega
  have h2 := refund_stale_decrements w (refund w s r) r hstale hlive' hcap
  rw [h1] at h2
  omega

/-- After a takeover, the new writer can still commit. -/
theorem takeover_keeps_new_writer_live (w : Workspace) (s : Signal) (r : Run)
    (h : r.epoch = (admit w s).1.epoch) : commitAllowed (admit w s).1 r := h.symm

end Ankole.SessionEpoch
