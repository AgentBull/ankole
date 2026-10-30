module

public import Std

@[expose] public section

/-
The PageDraftModel reload protocol.

`app/webapps/pod/state/page-draft.ts` keeps one editable document per Page.
A background `reload()` may resolve after the operator edits the document or
after the editor switches to another Page. The model keeps only the facts that
decide whether a resolving read may replace the draft: the source Page, the
draft and its saved baseline, the revision, the reload generation, and the
captured draft. Page identifiers and document bodies are modelled as `Nat`
tokens because only equality matters to the protocol.
-/

namespace Ankole.PageDraft

structure State where
  source : Option Nat
  xml : Nat
  savedXml : Nat
  revision : Nat
  generation : Nat
  conflict : Bool
  deriving Repr, DecidableEq

structure Request where
  source : Option Nat
  generation : Nat
  capturedXml : Nat
  deriving Repr, DecidableEq

def State.dirty (s : State) : Prop := s.xml ≠ s.savedXml

/- `reload()` captures the generation and the current draft before it awaits. -/
def startReload (s : State) : State × Request :=
  ( { s with generation := s.generation + 1 },
    { source := s.source, generation := s.generation + 1, capturedXml := s.xml } )

/-- A local edit after the read started. -/
def edit (s : State) (xml : Nat) : State := { s with xml := xml }

/-- `saved(content, version)` records a committed save without a source token. -/
def save (s : State) (content version : Nat) : State :=
  { s with savedXml := content, revision := version, conflict := false }

/-- `load(id, ...)` seeds a new source and bumps the generation, or returns early
for the current source. -/
def load (s : State) (source content version : Nat) : State :=
  if s.source = some source then s
  else
    { source := some source, xml := content, savedXml := content, revision := version,
      generation := s.generation + 1, conflict := false }

/-- `discard()` resets the draft to its saved baseline and cancels pending reads. -/
def discard (s : State) : State :=
  { s with xml := s.savedXml, generation := s.generation + 1, conflict := false }

/-- `cancelReload()` only invalidates the pending generation. -/
def cancel (s : State) : State := { s with generation := s.generation + 1 }

/-- A resolving read applies only when its generation and captured draft still
match the live draft and it does not move the revision backwards. -/
def resolve (s : State) (r : Request) (content version : Nat) : State :=
  if r.generation = s.generation ∧ s.xml = r.capturedXml ∧ ¬ version < s.revision then
    { s with xml := content, savedXml := content, revision := version, conflict := false }
  else s

/-- A rejecting read leaves the draft untouched; the hook only rethrows the
error when the same guards still hold. -/
def reject (s : State) (_r : Request) : State := s

theorem resolve_of_edited (s : State) (r : Request) (content version : Nat)
    (h : s.xml ≠ r.capturedXml) : resolve s r content version = s := by
  simp [resolve, h]

theorem resolve_of_stale_generation (s : State) (r : Request) (content version : Nat)
    (h : r.generation ≠ s.generation) : resolve s r content version = s := by
  simp [resolve, h]

theorem resolve_of_old_revision (s : State) (r : Request) (content version : Nat)
    (h : version < s.revision) : resolve s r content version = s := by
  simp [resolve, h]

theorem resolve_applied_equals_remote (s : State) (r : Request) (content version : Nat)
    (hgen : r.generation = s.generation) (hxml : s.xml = r.capturedXml)
    (hrev : ¬ version < s.revision) :
    resolve s r content version =
      { s with xml := content, savedXml := content, revision := version, conflict := false } := by
  simp [resolve, hgen, hxml, hrev]

theorem resolve_ignored_preserves_dirty (s : State) (r : Request) (content version : Nat)
    (h : s.xml ≠ r.capturedXml) :
    (resolve s r content version).dirty ↔ s.dirty := by
  simp [resolve, h]

theorem resolve_never_lowers_revision (s : State) (r : Request) (content version : Nat)
    (h : resolve s r content version ≠ s) : s.revision ≤ version := by
  by_cases hlt : version < s.revision
  · exact absurd (resolve_of_old_revision s r content version hlt) h
  · exact Nat.le_of_not_lt hlt

/-- Switching to another Page bumps the generation, so a read started on the
previous Page can no longer resolve. -/
theorem load_other_source_bumps (s : State) (source content version : Nat)
    (h : s.source ≠ some source) : (load s source content version).generation = s.generation + 1 := by
  simp [load, h]

theorem load_other_source_seeds (s : State) (source content version : Nat)
    (h : s.source ≠ some source) :
    (load s source content version).xml = content ∧
      (load s source content version).savedXml = content ∧
      (load s source content version).source = some source ∧
      (load s source content version).conflict = false := by
  simp [load, h]

theorem load_same_source_keeps (s : State) (source content version : Nat)
    (h : s.source = some source) : load s source content version = s := by
  simp [load, h]

/-- A pending read from the old Page cannot write the new Page's baseline after
`load` switched sources: its generation is strictly below the new generation. -/
theorem old_source_read_cannot_apply (s s' : State) (r : Request) (source content version _c _v : Nat)
    (hgen : r.generation = s.generation) (hload : s' = load s source content version)
    (hother : s.source ≠ some source) :
    resolve s' r _c _v = s' := by
  have hbump : s'.generation = s.generation + 1 := by
    simpa [hload] using load_other_source_bumps s source content version hother
  apply resolve_of_stale_generation
  omega

theorem discard_bumps_generation (s : State) : (discard s).generation = s.generation + 1 := rfl

theorem discard_resets_draft (s : State) : (discard s).xml = s.savedXml := rfl

theorem cancel_bumps_generation (s : State) : (cancel s).generation = s.generation + 1 := rfl

/-- `save` carries no source token. A collaboration callback from a previous
Page can therefore rewrite the current Page's saved baseline; this lemma names
the missing guard rather than proving safety. -/
theorem save_has_no_source_guard (s : State) (content version : Nat) :
    (save s content version).source = s.source := rfl

/-- A collaboration or rename callback carries no source token. Modelled as a
save-owner event: even when the event belongs to another Page, the current
Page's baseline changes. The model records the missing guard; production
relies on React effect cleanup to dispose the previous callback. -/
def saveFrom (s : State) (_source : Option Nat) (content version : Nat) : State :=
  save s content version

theorem stale_save_rewrites_baseline (s : State) (oldSource : Option Nat) (content version : Nat)
    (_h : oldSource ≠ s.source) : (saveFrom s oldSource content version).savedXml = content := rfl

/-- The production guard compares the read's own generation with the live one.
A read that is still the newest one can apply after a save; the revision check
is the only protection against replacing a newer commit. -/
theorem save_does_not_cancel_reload (s : State) (r : Request) (content version : Nat)
    (hgen : r.generation = s.generation) :
    (save s content version).generation = r.generation := by
  simp [save, hgen]

theorem reject_preserves_state (s : State) (r : Request) : reject s r = s := rfl

end Ankole.PageDraft
