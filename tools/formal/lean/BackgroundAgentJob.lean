module

public import Std

@[expose] public section

/-
Claim and slot accounting for one Background Agent Job.

`Ankole.BackgroundAgentJobs.Lifecycle` admits a Job attempt through
`claim_attempt` or `claim_continuation` while the Agent slot lock is held, and
`capacity_available_in_tx?` counts running Jobs. The model keeps one Job and the
Agent's running count; `maxRunning` is the resolved per-Agent cap.
-/

namespace Ankole.BackgroundAgentJob

inductive Status where
  | queued
  | running
  | waiting
  | succeeded
  | failed
  | stopped
  deriving Repr, DecidableEq

def terminal (s : Status) : Prop :=
  s = .succeeded ∨ s = .failed ∨ s = .stopped

instance (s : Status) : Decidable (terminal s) := by
  unfold terminal
  infer_instance

structure Job where
  status : Status
  attempts : Nat
  executionFailures : Nat
  consecutiveTurnFailures : Nat
  deriving Repr, DecidableEq

structure Pool where
  job : Job
  running : Nat
  maxRunning : Nat
  deriving Repr, DecidableEq

def maxClaims : Nat := 25
def maxExecutionFailures : Nat := 5
def maxConsecutiveTurnFailures : Nat := 5

def capacityAvailable (p : Pool) : Prop :=
  p.job.status = .running ∨ p.running < p.maxRunning

instance (p : Pool) : Decidable (capacityAvailable p) := by
  unfold capacityAvailable
  infer_instance

def canClaim (p : Pool) : Prop :=
  p.job.status = .queued ∧ p.job.executionFailures < maxExecutionFailures ∧
    p.job.attempts < maxClaims ∧ p.running < p.maxRunning

instance (p : Pool) : Decidable (canClaim p) := by
  unfold canClaim maxExecutionFailures maxClaims
  infer_instance

def canContinue (p : Pool) : Prop :=
  (p.job.status = .queued ∨ p.job.status = .waiting) ∧
    p.job.attempts < maxClaims ∧
    p.job.consecutiveTurnFailures < maxConsecutiveTurnFailures ∧
    p.running < p.maxRunning

instance (p : Pool) : Decidable (canContinue p) := by
  unfold canContinue maxConsecutiveTurnFailures maxClaims
  infer_instance

def startRunning (p : Pool) : Pool :=
  { p with job := { p.job with status := .running, attempts := p.job.attempts + 1 }, running := p.running + 1 }

def claimAttempt (p : Pool) : Pool := if canClaim p then startRunning p else p

def claimContinuation (p : Pool) : Pool := if canContinue p then startRunning p else p

def reportWaiting (p : Pool) : Pool :=
  if p.job.status = .running ∧ 0 < p.running then
    { p with job := { p.job with status := .waiting }, running := p.running - 1 }
  else p

def reportTerminal (p : Pool) (status : Status) : Pool :=
  if p.job.status = .running ∧ terminal status ∧ 0 < p.running then
    { p with job := { p.job with status := status }, running := p.running - 1 }
  else p

/-- A terminal execution failure releases the running slot and increments `executionFailures` without an artificial cap. -/
def failTerminal (p : Pool) : Pool :=
  if p.job.status = .running ∧ 0 < p.running then
    { p with
      job := { p.job with status := .failed, executionFailures := p.job.executionFailures + 1 },
      running := p.running - 1 }
  else p

/-- Returning a running Job to the queue releases the running slot and, when `charge` is true, records one execution failure without an artificial cap. -/
def requeue (p : Pool) (charge : Bool) : Pool :=
  if p.job.status = .running ∧ 0 < p.running then
    { p with
      job := { p.job with
        status := .queued,
        executionFailures := p.job.executionFailures + (if charge then 1 else 0) },
      running := p.running - 1 }
  else p

/- A stop leaves any live status; it only removes a running slot. -/
def stop (p : Pool) : Pool :=
  if (p.job.status = .queued ∨ p.job.status = .running ∨ p.job.status = .waiting) ∧
      (p.job.status ≠ .running ∨ 0 < p.running) then
    { p with job := { p.job with status := .stopped }, running := if p.job.status = .running then p.running - 1 else p.running }
  else p

theorem claim_rejected_on_terminal (p : Pool) (h : terminal p.job.status) : claimAttempt p = p := by
  rcases h with h | h | h <;> simp [claimAttempt, canClaim, h]

theorem continuation_rejected_on_terminal (p : Pool) (h : terminal p.job.status) :
    claimContinuation p = p := by
  rcases h with h | h | h <;> simp [claimContinuation, canContinue, h]

theorem terminal_absorbing (p : Pool) (status : Status) (charge : Bool)
    (h : terminal p.job.status) :
    claimAttempt p = p ∧ claimContinuation p = p ∧ reportWaiting p = p ∧
      reportTerminal p status = p ∧ failTerminal p = p ∧
      requeue p charge = p ∧ stop p = p := by
  refine ⟨claim_rejected_on_terminal p h, continuation_rejected_on_terminal p h, ?_, ?_, ?_, ?_, ?_⟩
  · rcases h with h | h | h <;> simp [reportWaiting, h]
  · rcases h with h | h | h <;> simp [reportTerminal, h]
  · rcases h with h | h | h <;> simp [failTerminal, h]
  · rcases h with h | h | h <;> simp [requeue, h]
  · rcases h with h | h | h <;> simp [stop, h]

theorem claim_rejected_at_claim_budget (p : Pool) (h : maxClaims ≤ p.job.attempts) :
    claimAttempt p = p := by
  have hlt : ¬ p.job.attempts < maxClaims := Nat.not_lt.mpr h
  simp [claimAttempt, canClaim, hlt]

theorem claim_rejected_at_failure_budget (p : Pool) (h : maxExecutionFailures ≤ p.job.executionFailures) :
    claimAttempt p = p := by
  have hlt : ¬ p.job.executionFailures < maxExecutionFailures := Nat.not_lt.mpr h
  simp [claimAttempt, canClaim, hlt]

theorem claim_rejected_at_capacity (p : Pool) (h : p.maxRunning ≤ p.running) :
    claimAttempt p = p := by
  have hlt : ¬ p.running < p.maxRunning := Nat.not_lt.mpr h
  simp [claimAttempt, canClaim, hlt]

theorem claim_charges_one (p : Pool) (h : canClaim p) : (claimAttempt p).job.attempts = p.job.attempts + 1 := by
  simp [claimAttempt, h, startRunning]

theorem claim_adds_one_slot (p : Pool) (h : canClaim p) : (claimAttempt p).running = p.running + 1 := by
  simp [claimAttempt, h, startRunning]

theorem continuation_rejected_at_capacity (p : Pool) (h : p.maxRunning ≤ p.running) :
    claimContinuation p = p := by
  have hlt : ¬ p.running < p.maxRunning := Nat.not_lt.mpr h
  simp [claimContinuation, canContinue, hlt]

/-- A steered continuation depends on the claim and consecutive-turn budgets rather than `executionFailures`, so an operator or user steer can resume a Job whose execution-failure count reached or passed `maxExecutionFailures`. -/
theorem continuation_resumes_past_failure_budget (p : Pool)
    (_hfail : maxExecutionFailures ≤ p.job.executionFailures) (hcont : canContinue p) :
    (claimContinuation p).job.status = .running ∧
      (claimContinuation p).job.attempts = p.job.attempts + 1 := by
  simp [claimContinuation, hcont, startRunning]

theorem waiting_releases_slot (p : Pool) (hstatus : p.job.status = .running) (hpos : 0 < p.running) :
    (reportWaiting p).running = p.running - 1 := by
  simp [reportWaiting, hstatus, hpos]

theorem waiting_status (p : Pool) (hstatus : p.job.status = .running) (hpos : 0 < p.running) :
    (reportWaiting p).job.status = .waiting := by
  simp [reportWaiting, hstatus, hpos]

theorem fail_terminal_increments_failures (p : Pool)
    (hstatus : p.job.status = .running) (hpos : 0 < p.running) :
    (failTerminal p).job.status = .failed ∧
      (failTerminal p).job.executionFailures = p.job.executionFailures + 1 ∧
      (failTerminal p).running = p.running - 1 := by
  simp [failTerminal, hstatus, hpos]

theorem requeue_charged_increments_failures (p : Pool)
    (hstatus : p.job.status = .running) (hpos : 0 < p.running) :
    (requeue p true).job.status = .queued ∧
      (requeue p true).job.executionFailures = p.job.executionFailures + 1 ∧
      (requeue p true).running = p.running - 1 := by
  simp [requeue, hstatus, hpos]

theorem requeue_uncharged_preserves_failures (p : Pool) :
    (requeue p false).job.executionFailures = p.job.executionFailures := by
  by_cases hc : p.job.status = .running ∧ 0 < p.running <;> simp [requeue, hc]

theorem requeue_at_failure_budget_blocks_claim (p : Pool)
    (hstatus : p.job.status = .running) (hpos : 0 < p.running)
    (hbudget : maxExecutionFailures ≤ p.job.executionFailures + 1) :
    claimAttempt (requeue p true) = requeue p true := by
  apply claim_rejected_at_failure_budget
  simp [requeue, hstatus, hpos]
  exact hbudget

theorem stop_releases_running_slot (p : Pool) (hstatus : p.job.status = .running) (hpos : 0 < p.running) :
    (stop p).running = p.running - 1 := by
  simp [stop, hstatus, hpos]

theorem stop_leaves_queued_slot (p : Pool) (hstatus : p.job.status = .queued) :
    (stop p).running = p.running := by
  simp [stop, hstatus]

theorem claim_preserves_slot_cap (p : Pool) (h : p.running ≤ p.maxRunning) :
    (claimAttempt p).running ≤ (claimAttempt p).maxRunning := by
  by_cases hc : canClaim p
  · simp [claimAttempt, hc, startRunning]
    have hlt : p.running < p.maxRunning := hc.2.2.2
    omega
  · simp [claimAttempt, hc]
    exact h

theorem continuation_preserves_slot_cap (p : Pool) (h : p.running ≤ p.maxRunning) :
    (claimContinuation p).running ≤ (claimContinuation p).maxRunning := by
  by_cases hc : canContinue p
  · simp [claimContinuation, hc, startRunning]
    have hlt : p.running < p.maxRunning := hc.2.2.2
    omega
  · simp [claimContinuation, hc]
    exact h

theorem waiting_preserves_slot_cap (p : Pool) (h : p.running ≤ p.maxRunning) :
    (reportWaiting p).running ≤ (reportWaiting p).maxRunning := by
  by_cases hc : p.job.status = .running ∧ 0 < p.running
  · simp [reportWaiting, hc]
    omega
  · simp [reportWaiting, hc]
    exact h

theorem fail_terminal_preserves_slot_cap (p : Pool) (h : p.running ≤ p.maxRunning) :
    (failTerminal p).running ≤ (failTerminal p).maxRunning := by
  by_cases hc : p.job.status = .running ∧ 0 < p.running
  · simp [failTerminal, hc]
    omega
  · simp [failTerminal, hc]
    exact h

theorem requeue_preserves_slot_cap (p : Pool) (charge : Bool) (h : p.running ≤ p.maxRunning) :
    (requeue p charge).running ≤ (requeue p charge).maxRunning := by
  by_cases hc : p.job.status = .running ∧ 0 < p.running
  · simp [requeue, hc]
    omega
  · simp [requeue, hc]
    exact h

theorem stop_preserves_slot_cap (p : Pool) (h : p.running ≤ p.maxRunning) :
    (stop p).running ≤ (stop p).maxRunning := by
  unfold stop
  by_cases hc : (p.job.status = .queued ∨ p.job.status = .running ∨ p.job.status = .waiting) ∧
      (p.job.status ≠ .running ∨ 0 < p.running)
  · rw [ite_eq_left hc]
    by_cases hr : p.job.status = .running
    · rw [ite_eq_left hr]
      have hpos : 0 < p.running := by
        rcases hc.2 with hne | hpos
        · exact absurd hr hne
        · exact hpos
      simp
      omega
    · rw [ite_eq_right hr]
      exact h
  · rw [ite_eq_right hc]
    exact h

/-- The counter invariant: no trace can exceed the per-Agent running cap. -/
theorem slot_cap_preserved (p : Pool) (h : p.running ≤ p.maxRunning) (status : Status)
    (charge : Bool) :
    (claimAttempt p).running ≤ (claimAttempt p).maxRunning ∧
      (claimContinuation p).running ≤ (claimContinuation p).maxRunning ∧
      (reportWaiting p).running ≤ (reportWaiting p).maxRunning ∧
      (reportTerminal p status).running ≤ (reportTerminal p status).maxRunning ∧
      (failTerminal p).running ≤ (failTerminal p).maxRunning ∧
      (requeue p charge).running ≤ (requeue p charge).maxRunning ∧
      (stop p).running ≤ (stop p).maxRunning := by
  refine ⟨claim_preserves_slot_cap p h, continuation_preserves_slot_cap p h,
    waiting_preserves_slot_cap p h, ?_, fail_terminal_preserves_slot_cap p h,
    requeue_preserves_slot_cap p charge h, stop_preserves_slot_cap p h⟩
  by_cases hc : p.job.status = .running ∧ terminal status ∧ 0 < p.running
  · simp [reportTerminal, hc]
    omega
  · simp [reportTerminal, hc]
    exact h

theorem continuation_attempts_bounded (p : Pool) (h : p.job.attempts ≤ maxClaims) :
    (claimContinuation p).job.attempts ≤ maxClaims := by
  by_cases hc : canContinue p
  · have hlt : p.job.attempts < maxClaims := hc.2.1
    simp [claimContinuation, hc, startRunning]
    omega
  · simp [claimContinuation, hc]
    exact h

theorem attempts_bounded (p : Pool) (h : p.job.attempts ≤ maxClaims) :
    (claimAttempt p).job.attempts ≤ maxClaims := by
  by_cases hc : canClaim p
  · have hlt : p.job.attempts < maxClaims := hc.2.2.1
    simp [claimAttempt, hc, startRunning]
    omega
  · simp [claimAttempt, hc]
    exact h

end Ankole.BackgroundAgentJob
