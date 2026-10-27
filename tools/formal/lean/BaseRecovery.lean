module
public import Std
@[expose] public section
namespace Ankole.BaseRecovery

-- These are committed database snapshots. Each transition is one local commit.
inductive Mode where | inline | physical
  deriving DecidableEq
structure State where
  mode : Mode
  inlineRows : List Nat
  shardRows : Option (List Nat)
  metadataVersion : Nat
  shardVersion : Nat
  deleting : Bool
  metadataExists : Bool
  deriving DecidableEq

-- A retry rebuilds from current authoritative inline rows, not residual shard rows.
def stagePromotion (s : State) : State :=
  {s with shardRows := some s.inlineRows, shardVersion := s.metadataVersion + 1}

def commitPromotion (s : State) : State :=
  if s.mode = .inline ∧ s.shardRows = some s.inlineRows ∧
      s.shardVersion = s.metadataVersion + 1 then
    {s with mode := .physical, inlineRows := [], metadataVersion := s.shardVersion}
  else s

def authoritativeRows (s : State) : Option (List Nat) :=
  match s.mode with
  | .inline => some s.inlineRows
  | .physical => if s.metadataVersion = s.shardVersion then s.shardRows else none

theorem crash_before_metadata_keeps_inline (s : State) (h : s.mode = .inline) :
    authoritativeRows (stagePromotion s) = some s.inlineRows := by
  simp [authoritativeRows, stagePromotion, h]

theorem completed_promotion_preserves_rows (s : State) (h : s.mode = .inline) :
    authoritativeRows (commitPromotion (stagePromotion s)) = some s.inlineRows := by
  simp [authoritativeRows, commitPromotion, stagePromotion, h]

theorem retry_discards_residue (s : State) (residue : Option (List Nat)) :
    stagePromotion {s with shardRows := residue} = stagePromotion s := rfl

def commitShardDDL (s : State) : State := {s with shardVersion := s.shardVersion + 1}

theorem ddl_partial_commit_fails_closed (s : State) (mode : s.mode = .physical)
    (versions : s.metadataVersion = s.shardVersion) :
    authoritativeRows (commitShardDDL s) = none := by
  simp [authoritativeRows, commitShardDDL, mode, versions]

-- A successful SELECT 1 is not a two-database commit protocol.
example : ∃ s, s.mode = .physical ∧ s.metadataVersion = s.shardVersion ∧
    (commitShardDDL s).metadataVersion ≠ (commitShardDDL s).shardVersion := by
  refine ⟨⟨.physical, [], some [1], 0, 0, false, true⟩, ?_⟩
  decide

def markDelete (s : State) := {s with deleting := true}
def dropShard (s : State) := if s.deleting then {s with shardRows := none} else s
def removeMetadata (s : State) :=
  if s.deleting ∧ s.shardRows = none then {s with metadataExists := false} else s
def visible (s : State) := s.metadataExists && !s.deleting

theorem marked_table_is_hidden (s : State) : visible (markDelete s) = false := by
  simp [visible, markDelete]

theorem drop_is_idempotent (s : State) : dropShard (dropShard s) = dropShard s := by
  cases h : s.deleting <;> simp [dropShard, h]

theorem remove_is_idempotent (s : State) : removeMetadata (removeMetadata s) = removeMetadata s := by
  unfold removeMetadata
  split <;> simp_all

theorem deletion_finishes_after_retry (s : State) :
    (removeMetadata (dropShard (markDelete s))).metadataExists = false ∧
      (removeMetadata (dropShard (markDelete s))).shardRows = none := by
  simp [removeMetadata, dropShard, markDelete]

theorem metadata_removal_requires_shard_cleanup (s : State) (existsBefore : s.metadataExists = true)
    (removed : (removeMetadata s).metadataExists = false) : s.shardRows = none := by
  unfold removeMetadata at removed
  split at removed <;> simp_all
end Ankole.BaseRecovery
