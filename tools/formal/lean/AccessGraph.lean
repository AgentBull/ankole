module
public import Std
@[expose] public section
namespace Ankole.AccessGraph

-- Nodes include page, scope, and action. An edge imports one dependency.
inductive Reach {Node : Type} (seed : Node → Prop) (edge : Node → Node → Prop) : Node → Prop
  | seed {n} : seed n → Reach seed edge n
  | dependency {n p} : edge n p → Reach seed edge p → Reach seed edge n

theorem reach_has_seed {Node : Type} {seed : Node → Prop} {edge : Node → Node → Prop}
    {n} (h : Reach seed edge n) : ∃ s, seed s := by
  induction h with
  | seed hs => exact ⟨_, hs⟩
  | dependency _ _ ih => exact ih

theorem cycle_without_seed_denies {Node : Type} (edge : Node → Node → Prop) (n : Node) :
    ¬ Reach (fun _ => False) edge n := by
  intro h
  obtain ⟨_, impossible⟩ := reach_has_seed h
  exact impossible

theorem monotone {Node : Type} {a b : Node → Prop} {edge : Node → Node → Prop}
    (h : ∀ n, a n → b n) {n} : Reach a edge n → Reach b edge n := by
  intro reach
  induction reach with
  | seed hs => exact .seed (h _ hs)
  | dependency he _ ih => exact .dependency he ih

-- An inherited page with no local seed and one dependency can use that anchor.
theorem transparent_anchor {Node : Type} {seed : Node → Prop} {edge : Node → Node → Prop}
    {page parent} (empty : ¬ seed page) (only : ∀ n, edge page n ↔ n = parent) :
    Reach seed edge page ↔ Reach seed edge parent := by
  constructor
  · intro h
    cases h with
    | seed hs => exact False.elim (empty hs)
    | dependency he hp => simpa [only _ |>.mp he] using hp
  · intro h
    exact .dependency ((only parent).mpr rfl) h

-- Human and Agent checks intersect; either denial is sufficient.
def effective (human agent : Prop) := human ∧ agent

theorem intersection_no_escalation (human agent : Prop) :
    effective human agent → human ∧ agent := id

-- Symbolic atoms denote subjects or groups. Equality must hold for every actor,
-- not only for the editor who requests the move.
def evaluates {Atom : Type} (policy : Atom → Prop) (actor : Atom → Prop) : Prop :=
  ∃ atom, policy atom ∧ actor atom

theorem equal_incoming_preserves_all_actors {Atom : Type} {before afterMove localPolicy : Atom → Prop}
    (same : before = afterMove) (actor : Atom → Prop) :
    evaluates (fun a => localPolicy a ∨ before a) actor ↔
      evaluates (fun a => localPolicy a ∨ afterMove a) actor := by
  subst afterMove
  rfl

-- The four action bits are independent; role expansion belongs to grant creation.
example : ¬ ((fun n : Nat => n = 8) 8 → (fun n : Nat => n = 8) 1) := by decide
end Ankole.AccessGraph
