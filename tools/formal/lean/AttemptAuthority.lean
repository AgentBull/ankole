module
public import Std
@[expose] public section
namespace Ankole.AttemptAuthority

inductive Authorization where | human (capturedVersion : Nat) | service | review
  deriving DecidableEq

-- Admission checks the Job and authorizing Human before starting an attempt.
structure Admission where
  jobActive : Bool
  humanActive : Bool
  humanVersion : Nat
  authorization : Authorization
  deriving DecidableEq

def humanAllowed (a : Admission) : Prop := match a.authorization with
  | .human v => a.humanActive = true ∧ a.humanVersion = v
  | .service => True
  | .review => False
instance (a : Admission) : Decidable (humanAllowed a) := by
  unfold humanAllowed
  split <;> infer_instance

def mayAdmit (a : Admission) : Prop := a.jobActive = true ∧ humanAllowed a
instance (a : Admission) : Decidable (mayAdmit a) := inferInstanceAs (Decidable (_ ∧ _))

-- These are the current rows fetched and locked by AttemptAccess. IDs stand for
-- the domain's validated identifiers; resource permissions are checked separately.
structure Facts where
  jobExists : Bool
  job : Nat
  run : Nat
  runRunning : Bool
  runJob : Nat
  attempt : Nat
  principalExists : Bool
  deriving DecidableEq
structure Request where
  job : Nat
  run : Nat
  attempt : Nat
  principal : Nat
  actorPrincipal : Nat
  deriving DecidableEq

def allowed (f : Facts) (r : Request) : Prop :=
  f.jobExists = true ∧ f.job = r.job ∧ f.run = r.run ∧ f.runRunning = true ∧
    f.runJob = r.job ∧ f.attempt = r.attempt ∧ f.principalExists = true ∧
    r.principal = r.actorPrincipal
instance (f : Facts) (r : Request) : Decidable (allowed f r) := inferInstanceAs (Decidable (_ ∧ _))

-- Resource authorization must also succeed before the owning transaction commits.
def write (f : Facts) (r : Request) (durable : List Nat) (value : Nat) : List Nat :=
  if allowed f r then durable ++ [value] else durable

theorem replaced_attempt_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (stale : f.attempt ≠ r.attempt) : write f r d v = d := by
  simp [write, allowed, stale]

theorem mismatched_job_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (mismatch : f.runJob ≠ r.job) : write f r d v = d := by
  simp [write, allowed, mismatch]

theorem mismatched_run_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (mismatch : f.run ≠ r.run) : write f r d v = d := by
  simp [write, allowed, mismatch]

theorem mismatched_actor_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (mismatch : r.principal ≠ r.actorPrincipal) : write f r d v = d := by
  simp [write, allowed, mismatch]

theorem finished_attempt_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (finished : f.runRunning = false) : write f r d v = d := by
  simp [write, allowed, finished]

theorem deleted_job_cannot_write (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (deleted : f.jobExists = false) : write f r d v = d := by
  simp [write, allowed, deleted]

theorem committed_write_has_current_authority (f : Facts) (r : Request) (d : List Nat) (v : Nat)
    (changed : write f r d v ≠ d) : allowed f r := by
  by_cases h : allowed f r
  · exact h
  · simp [write, h] at changed

theorem revoked_human_cannot_start (a : Admission) (captured : Nat)
    (auth : a.authorization = .human captured) (stale : a.humanVersion ≠ captured) :
    ¬ mayAdmit a := by simp [mayAdmit, humanAllowed, auth, stale]

theorem inactive_job_cannot_start (a : Admission) (inactive : a.jobActive = false) :
    ¬ mayAdmit a := by simp [mayAdmit, inactive]

theorem review_cannot_start (a : Admission) (review : a.authorization = .review) :
    ¬ mayAdmit a := by simp [mayAdmit, humanAllowed, review]

-- Offboarding changes admission, not an already admitted attempt's live fence.
-- The owning resource still applies its ordinary authorization at every write.
example : ∃ a f r, mayAdmit a ∧
    ¬ mayAdmit {a with humanActive := false, humanVersion := a.humanVersion + 1} ∧
    allowed f r := by
  refine ⟨⟨true, true, 0, .human 0⟩, ⟨true, 9, 11, true, 9, 1, true⟩,
    ⟨9, 11, 1, 7, 7⟩, ?_⟩
  decide

-- Permission at an earlier snapshot cannot authorize a replaced attempt.
example : ∃ f r, allowed f r ∧ ¬ allowed {f with attempt := f.attempt + 1} r := by
  refine ⟨⟨true, 9, 11, true, 9, 1, true⟩, ⟨9, 11, 1, 7, 7⟩, ?_⟩
  decide
end Ankole.AttemptAuthority
