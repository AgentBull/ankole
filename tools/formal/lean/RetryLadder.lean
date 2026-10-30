module

public import Std

@[expose] public section

/-
The retry ladder policy of `Ankole.Sessions.TurnErrorClassifier`.

`delay_seconds/3` selects one fixed ladder for Job failures and uses an
exponential ladder for conversation execution failures. The model proves that
every branch is bounded and saturates at the last rung. The owning ExUnit suite
drives the production function over every distinct clamp value and the
saturation range.
-/

namespace Ankole.RetryLadder

def conversationExecution (attempt : Nat) : Nat :=
  min (5 * 2 ^ min (attempt - 1) 5) 120

def jobExecution (attempt : Nat) : Nat :=
  match min (attempt - 1) 4 with
  | 0 => 60
  | 1 => 600
  | 2 => 1800
  | 3 => 3600
  | _ => 7200

def jobInfrastructure (attempt : Nat) : Nat :=
  match min (attempt - 1) 4 with
  | 0 => 15
  | 1 => 30
  | 2 => 60
  | 3 => 120
  | _ => 300

def conversationCapacity (attempt : Nat) : Nat :=
  match min (attempt - 1) 3 with
  | 0 => 30
  | 1 => 120
  | 2 => 300
  | _ => 750

theorem conversation_execution_bounded (attempt : Nat) : conversationExecution attempt ≤ 120 := by
  unfold conversationExecution
  exact Nat.min_le_right _ _

theorem conversation_execution_at_zero : conversationExecution 0 = 5 := rfl

theorem conversation_execution_saturates (attempt : Nat) (h : 6 ≤ attempt) :
    conversationExecution attempt = 120 := by
  unfold conversationExecution
  have hmin : min (attempt - 1) 5 = 5 := by omega
  rw [hmin]
  decide

theorem conversation_execution_monotone (a b : Nat) (h : a ≤ b) :
    conversationExecution a ≤ conversationExecution b := by
  unfold conversationExecution
  have hmin : min (a - 1) 5 ≤ min (b - 1) 5 := by
    rw [Nat.min_def, Nat.min_def]
    split <;> split <;> omega
  have hpow : 2 ^ min (a - 1) 5 ≤ 2 ^ min (b - 1) 5 :=
    Nat.pow_le_pow_right (by decide) hmin
  have hmul : 5 * 2 ^ min (a - 1) 5 ≤ 5 * 2 ^ min (b - 1) 5 :=
    Nat.mul_le_mul_left 5 hpow
  by_cases hb : 5 * 2 ^ min (b - 1) 5 ≤ 120
  · rw [Nat.min_eq_left hb]
    exact Nat.le_trans (Nat.min_le_left _ _) hmul
  · have hb' : 120 ≤ 5 * 2 ^ min (b - 1) 5 := by omega
    rw [Nat.min_eq_right hb']
    exact Nat.min_le_right _ _

theorem job_execution_bounded (attempt : Nat) : jobExecution attempt ≤ 7200 := by
  unfold jobExecution
  split <;> omega

theorem job_execution_at_zero : jobExecution 0 = 60 := rfl

theorem job_execution_saturates (attempt : Nat) (h : 5 ≤ attempt) :
    jobExecution attempt = 7200 := by
  unfold jobExecution
  have hmin : min (attempt - 1) 4 = 4 := by omega
  rw [hmin]
  rfl

theorem job_infrastructure_bounded (attempt : Nat) : jobInfrastructure attempt ≤ 300 := by
  unfold jobInfrastructure
  split <;> omega

theorem job_infrastructure_saturates (attempt : Nat) (h : 5 ≤ attempt) :
    jobInfrastructure attempt = 300 := by
  unfold jobInfrastructure
  have hmin : min (attempt - 1) 4 = 4 := by omega
  rw [hmin]
  rfl

theorem conversation_capacity_bounded (attempt : Nat) : conversationCapacity attempt ≤ 750 := by
  unfold conversationCapacity
  split <;> omega

theorem conversation_capacity_saturates (attempt : Nat) (h : 4 ≤ attempt) :
    conversationCapacity attempt = 750 := by
  unfold conversationCapacity
  have hmin : min (attempt - 1) 3 = 3 := by omega
  rw [hmin]
  rfl

end Ankole.RetryLadder
