module

public import Std

@[expose] public section

/-
The outbound delivery intent lifecycle.

`Ankole.Conversations.Delivery.Intent` is a durable state machine for one
provider operation. A pending row has a bounded attempt budget; a timestamp
fences one in-flight provider call; `sent`, `unknown`, and `expired` stop
automatic work. This model keeps the facts that decide admission and records
the transitions the production actions expose.
-/

namespace Ankole.DeliveryIntent

inductive Status where
  | pending
  | sent
  | failed
  | expired
  | unknown
  deriving Repr, DecidableEq

inductive Recovery where
  | blocked
  | permanent
  | exhausted
  deriving Repr, DecidableEq

structure State where
  status : Status
  attempts : Nat
  maxAttempts : Nat
  inFlight : Bool
  recovery : Option Recovery
  possibleDuplicate : Bool
  nextAttemptAt : Option Nat
  deriving Repr, DecidableEq

structure Claim where
  attempts : Nat
  startedAt : Nat
  deriving Repr, DecidableEq

def initial (maxAttempts : Nat) : State :=
  { status := .pending, attempts := 0, maxAttempts := maxAttempts, inFlight := false,
    recovery := none, possibleDuplicate := false, nextAttemptAt := none }

def canStart (s : State) : Prop :=
  (s.status = .pending ∨ (s.status = .failed ∧ s.possibleDuplicate = false)) ∧
    s.inFlight = false ∧ s.recovery = none ∧ s.attempts < s.maxAttempts

instance (s : State) : Decidable (canStart s) := by
  unfold canStart
  infer_instance

/- `start_attempt`: claim the row for one provider call and charge the attempt. -/
def startAttempt (s : State) : State :=
  if canStart s then
    { s with status := .pending, attempts := s.attempts + 1, inFlight := true, nextAttemptAt := none }
  else s

/-- `succeed`: the provider returned a durable identity for this attempt. -/
def succeed (s : State) : State :=
  if s.status = .pending then
    { s with status := .sent, inFlight := false, recovery := none, nextAttemptAt := none }
  else s

/-- `fail`: the provider rejected this attempt; recovery policy owns the retry time. -/
def fail (s : State) (recovery : Option Recovery) (next : Option Nat) : State :=
  if s.status = .pending ∨ s.status = .failed then
    { s with status := .failed, inFlight := false, recovery := recovery, nextAttemptAt := next }
  else s

/-- `mark_unknown`: no provable provider outcome; only an operator may continue. -/
def markUnknown (s : State) : State :=
  if s.status = .pending then
    { s with status := .unknown, inFlight := false, nextAttemptAt := none }
  else s

/-- `expire`: the intent outlived its delivery window. -/
def expire (s : State) : State :=
  if s.status = .pending ∨ s.status = .failed then
    { s with status := .expired, inFlight := false, recovery := none, nextAttemptAt := none }
  else s

/-- `requeue`: an explicit operator retry. It commits no automatic retry and
grants exactly one further attempt on the same row. -/
def requeue (s : State) (now : Nat) : State :=
  if (s.status = .failed ∨ s.status = .unknown) ∧ s.nextAttemptAt = none then
    { s with status := .pending, maxAttempts := s.attempts + 1, inFlight := false, recovery := none, nextAttemptAt := some now }
  else s

/-- The dispatch fence: only the claimed attempt may record a provider outcome. -/
def finalize (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status) : State :=
  if s.status = .pending ∧ s.inFlight ∧ s.attempts = claim.attempts ∧
      startedAt = claim.startedAt then
    { s with status := outcome, inFlight := false, nextAttemptAt := none }
  else s

theorem start_sent_is_noop (s : State) (h : s.status = .sent) : startAttempt s = s := by
  simp [startAttempt, canStart, h]

theorem start_unknown_is_noop (s : State) (h : s.status = .unknown) : startAttempt s = s := by
  simp [startAttempt, canStart, h]

theorem start_in_flight_is_noop (s : State) (h : s.inFlight = true) : startAttempt s = s := by
  simp [startAttempt, canStart, h]

theorem start_recovery_is_noop (s : State) (h : s.recovery ≠ none) : startAttempt s = s := by
  simp [startAttempt, canStart, h]

theorem start_failed_duplicate_is_noop (s : State) (hs : s.status = .failed)
    (hd : s.possibleDuplicate = true) : startAttempt s = s := by
  simp [startAttempt, canStart, hs, hd]

theorem start_exhausted_is_noop (s : State) (h : s.maxAttempts ≤ s.attempts) : startAttempt s = s := by
  simp [startAttempt, canStart, Nat.not_lt.mpr h]

theorem succeed_leaves_sent (s : State) (h : s.status = .sent) : succeed s = s := by
  simp [succeed, h]

theorem fail_leaves_sent (s : State) (recovery : Option Recovery) (next : Option Nat)
    (h : s.status = .sent) : fail s recovery next = s := by
  simp [fail, h]

theorem unknown_leaves_sent (s : State) (h : s.status = .sent) : markUnknown s = s := by
  simp [markUnknown, h]

theorem expire_leaves_sent (s : State) (h : s.status = .sent) : expire s = s := by
  simp [expire, h]

theorem requeue_leaves_sent (s : State) (now : Nat) (h : s.status = .sent) : requeue s now = s := by
  simp [requeue, h]

theorem finalize_leaves_sent (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (h : s.status = .sent) : finalize s claim startedAt outcome = s := by
  simp [finalize, h]

/-- No transition can move a `sent` intent back into provider work. -/
theorem sent_absorbing (s : State) (now startedAt : Nat) (claim : Claim)
    (recovery : Option Recovery) (next : Option Nat) (outcome : Status)
    (h : s.status = .sent) :
    startAttempt s = s ∧ succeed s = s ∧ fail s recovery next = s ∧
      markUnknown s = s ∧ expire s = s ∧ requeue s now = s ∧
      finalize s claim startedAt outcome = s := by
  exact ⟨start_sent_is_noop s h, succeed_leaves_sent s h, fail_leaves_sent s recovery next h,
    unknown_leaves_sent s h, expire_leaves_sent s h, requeue_leaves_sent s now h,
    finalize_leaves_sent s claim startedAt outcome h⟩

theorem start_expired_is_noop (s : State) (h : s.status = .expired) : startAttempt s = s := by
  simp [startAttempt, canStart, h]

theorem succeed_leaves_expired (s : State) (h : s.status = .expired) : succeed s = s := by
  simp [succeed, h]

theorem fail_leaves_expired (s : State) (recovery : Option Recovery) (next : Option Nat)
    (h : s.status = .expired) : fail s recovery next = s := by
  simp [fail, h]

theorem unknown_leaves_expired (s : State) (h : s.status = .expired) : markUnknown s = s := by
  simp [markUnknown, h]

theorem expire_leaves_expired (s : State) (h : s.status = .expired) : expire s = s := by
  simp [expire, h]

theorem requeue_leaves_expired (s : State) (now : Nat) (h : s.status = .expired) :
    requeue s now = s := by
  simp [requeue, h]

theorem finalize_leaves_expired (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (h : s.status = .expired) : finalize s claim startedAt outcome = s := by
  simp [finalize, h]

/-- No transition can move an `expired` intent back into provider work. -/
theorem expired_absorbing (s : State) (now startedAt : Nat) (claim : Claim)
    (recovery : Option Recovery) (next : Option Nat) (outcome : Status)
    (h : s.status = .expired) :
    startAttempt s = s ∧ succeed s = s ∧ fail s recovery next = s ∧
      markUnknown s = s ∧ expire s = s ∧ requeue s now = s ∧
      finalize s claim startedAt outcome = s := by
  exact ⟨start_expired_is_noop s h, succeed_leaves_expired s h,
    fail_leaves_expired s recovery next h, unknown_leaves_expired s h,
    expire_leaves_expired s h, requeue_leaves_expired s now h,
    finalize_leaves_expired s claim startedAt outcome h⟩

theorem start_charges_one (s : State) (h : canStart s) :
    (startAttempt s).attempts = s.attempts + 1 := by
  simp [startAttempt, h]

theorem start_is_pending (s : State) (h : canStart s) :
    (startAttempt s).status = .pending := by
  simp [startAttempt, h]

theorem start_clears_schedule (s : State) (h : canStart s) :
    (startAttempt s).nextAttemptAt = none := by
  simp [startAttempt, h]

theorem start_sets_in_flight (s : State) (h : canStart s) :
    (startAttempt s).inFlight = true := by
  simp [startAttempt, h]

theorem requeue_grants_exactly_one (s : State) (now : Nat)
    (h : s.status = .failed ∨ s.status = .unknown) (hnext : s.nextAttemptAt = none) :
    (requeue s now).maxAttempts = s.attempts + 1 := by
  simp [requeue, h, hnext]

theorem requeue_keeps_attempts (s : State) (now : Nat) :
    (requeue s now).attempts = s.attempts := by
  by_cases h : (s.status = .failed ∨ s.status = .unknown) ∧ s.nextAttemptAt = none <;>
    simp [requeue, h]

theorem requeue_clears_recovery (s : State) (now : Nat)
    (h : (s.status = .failed ∨ s.status = .unknown) ∧ s.nextAttemptAt = none) :
    (requeue s now).recovery = none := by
  simp [requeue, h]

theorem requeue_schedules_now (s : State) (now : Nat)
    (h : (s.status = .failed ∨ s.status = .unknown) ∧ s.nextAttemptAt = none) :
    (requeue s now).nextAttemptAt = some now := by
  simp [requeue, h]

theorem requeue_requires_stopped (s : State) (now : Nat)
    (h : s.status = .pending ∨ s.status = .sent ∨ s.status = .expired) :
    requeue s now = s := by
  rcases h with h | h | h <;> simp [requeue, h]

/-- Without an explicit `requeue`, every other operation leaves an `unknown` intent unchanged. -/
theorem unknown_requires_explicit_requeue (s : State) (startedAt : Nat) (claim : Claim)
    (recovery : Option Recovery) (next : Option Nat) (outcome : Status)
    (h : s.status = .unknown) :
    startAttempt s = s ∧ succeed s = s ∧ fail s recovery next = s ∧
      markUnknown s = s ∧ expire s = s ∧ finalize s claim startedAt outcome = s := by
  exact ⟨start_unknown_is_noop s h, by simp [succeed, h], by simp [fail, h],
    by simp [markUnknown, h], by simp [expire, h], by simp [finalize, h]⟩

/-- A result recorded for an older attempt cannot rewrite the current one. -/
theorem stale_finalize_is_noop (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (h : claim.attempts ≠ s.attempts) : finalize s claim startedAt outcome = s := by
  have h' : s.attempts ≠ claim.attempts := fun hs => h hs.symm
  simp [finalize, h']

theorem stale_started_at_is_noop (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (h : startedAt ≠ claim.startedAt) : finalize s claim startedAt outcome = s := by
  simp [finalize, h]

theorem finalize_not_pending_is_noop (s : State) (claim : Claim) (startedAt : Nat)
    (outcome : Status) (h : s.status ≠ .pending) : finalize s claim startedAt outcome = s := by
  simp [finalize, h]

theorem finalize_applies (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (hstatus : s.status = .pending) (hin : s.inFlight = true) (hattempt : s.attempts = claim.attempts)
    (hstart : startedAt = claim.startedAt) :
    (finalize s claim startedAt outcome).status = outcome := by
  simp [finalize, hstatus, hin, hattempt, hstart]

/-- Every transition preserves the attempt budget. -/
theorem succeed_preserves_budget (s : State) (h : s.attempts ≤ s.maxAttempts) :
    (succeed s).attempts ≤ (succeed s).maxAttempts := by
  by_cases hp : s.status = .pending <;> simp [succeed, hp] <;> omega

theorem fail_preserves_budget (s : State) (recovery : Option Recovery) (next : Option Nat)
    (h : s.attempts ≤ s.maxAttempts) :
    (fail s recovery next).attempts ≤ (fail s recovery next).maxAttempts := by
  by_cases hp : s.status = .pending ∨ s.status = .failed <;> simp [fail, hp] <;> omega

theorem unknown_preserves_budget (s : State) (h : s.attempts ≤ s.maxAttempts) :
    (markUnknown s).attempts ≤ (markUnknown s).maxAttempts := by
  by_cases hp : s.status = .pending <;> simp [markUnknown, hp] <;> omega

theorem expire_preserves_budget (s : State) (h : s.attempts ≤ s.maxAttempts) :
    (expire s).attempts ≤ (expire s).maxAttempts := by
  by_cases hp : s.status = .pending ∨ s.status = .failed <;> simp [expire, hp] <;> omega

theorem requeue_preserves_budget (s : State) (now : Nat) (h : s.attempts ≤ s.maxAttempts) :
    (requeue s now).attempts ≤ (requeue s now).maxAttempts := by
  by_cases hp : (s.status = .failed ∨ s.status = .unknown) ∧ s.nextAttemptAt = none <;>
    simp [requeue, hp] <;> omega

theorem finalize_preserves_budget (s : State) (claim : Claim) (startedAt : Nat) (outcome : Status)
    (h : s.attempts ≤ s.maxAttempts) :
    (finalize s claim startedAt outcome).attempts ≤
      (finalize s claim startedAt outcome).maxAttempts := by
  by_cases hp : s.status = .pending ∧ s.inFlight = true ∧ s.attempts = claim.attempts ∧
      startedAt = claim.startedAt <;>
    simp [finalize, hp] <;> omega

theorem budget_preserved (s : State) (h : s.attempts ≤ s.maxAttempts) (now startedAt : Nat)
    (claim : Claim) (recovery : Option Recovery) (next : Option Nat) (outcome : Status) :
    (startAttempt s).attempts ≤ (startAttempt s).maxAttempts ∧
      (succeed s).attempts ≤ (succeed s).maxAttempts ∧
      (fail s recovery next).attempts ≤ (fail s recovery next).maxAttempts ∧
      (markUnknown s).attempts ≤ (markUnknown s).maxAttempts ∧
      (expire s).attempts ≤ (expire s).maxAttempts ∧
      (requeue s now).attempts ≤ (requeue s now).maxAttempts ∧
      (finalize s claim startedAt outcome).attempts ≤
        (finalize s claim startedAt outcome).maxAttempts := by
  refine ⟨?_, succeed_preserves_budget s h, fail_preserves_budget s recovery next h,
    unknown_preserves_budget s h, expire_preserves_budget s h, requeue_preserves_budget s now h,
    finalize_preserves_budget s claim startedAt outcome h⟩
  by_cases hc : canStart s
  · have hlt : s.attempts < s.maxAttempts := hc.2.2.2
    simp [startAttempt, hc]
    omega
  · simp [startAttempt, hc]
    exact h

end Ankole.DeliveryIntent
