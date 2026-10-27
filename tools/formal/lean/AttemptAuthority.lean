module
public import Std
@[expose] public section
namespace Ankole.AttemptAuthority

inductive Authorization where | human (capturedVersion : Nat) | service | review
  deriving DecidableEq
structure Facts where
  jobActive : Bool
  runRunning : Bool
  assignedAgent : Nat
  runJob : Nat
  attempt : Nat
  humanActive : Bool
  humanVersion : Nat
  authorization : Authorization
  deriving DecidableEq
structure Request where
  agent : Nat
  job : Nat
  attempt : Nat
  deriving DecidableEq

def humanAllowed (f : Facts) : Prop := match f.authorization with
  | .human v => f.humanActive = true ∧ f.humanVersion = v
  | .service => True
  | .review => False
instance (f : Facts) : Decidable (humanAllowed f) := by
  unfold humanAllowed
  split <;> infer_instance

def allowed (f : Facts) (r : Request) : Prop :=
  f.jobActive = true ∧ f.runRunning = true ∧ f.assignedAgent = r.agent ∧
    f.runJob = r.job ∧ f.attempt = r.attempt ∧ humanAllowed f
instance (f : Facts) (r : Request) : Decidable (allowed f r) := inferInstanceAs (Decidable (_ ∧ _))

-- The write rechecks current facts under the transaction's row locks.
def write (f : Facts) (r : Request) (durable : List Nat) (value : Nat) : List Nat :=
  if allowed f r then durable ++ [value] else durable

theorem replaced_attempt_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (stale : f.attempt ≠ r.attempt) : write f r d v = d := by
  simp [write, allowed, stale]

theorem revoked_human_cannot_write (f : Facts) (r : Request) (d : List Nat) (v captured : Nat)
    (auth : f.authorization = .human captured) (stale : f.humanVersion ≠ captured) :
    write f r d v = d := by simp [write, allowed, humanAllowed, auth, stale]

theorem inactive_job_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (inactive : f.jobActive = false) : write f r d v = d := by simp [write, allowed, inactive]

theorem committed_write_has_current_authority (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (changed : write f r d v ≠ d) : allowed f r := by
  by_cases h : allowed f r
  · exact h
  · simp [write, h] at changed

-- Permission at an earlier snapshot alone cannot authorize a later write.
example : ∃ f r, allowed f r ∧ ¬ allowed {f with attempt := f.attempt + 1} r := by
  refine ⟨⟨true, true, 7, 9, 1, false, 0, .service⟩, ⟨7, 9, 1⟩, ?_⟩
  decide
end Ankole.AttemptAuthority
