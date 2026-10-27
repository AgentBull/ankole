module
public import Lynx.Modules.Erlang.maps
public import Lynx.Modules.Erlang.lists
@[expose] public section
namespace Ankole.RuntimeSupport
open Lynx

-- The extension must emit each visible binding exactly once, in mapEntries order.
inductive IteratorContents : Term → List (Term × Term) → Prop
  | empty : IteratorContents (.atom "none") []
  | next {tail entries key value} : IteratorContents tail entries →
      IteratorContents (.tuple #[key, value, tail]) ((key, value) :: entries)

theorem iterator_all_entries (entries : List (Term × Term)) :
    IteratorContents
      (entries.foldr (fun (key, value) tail => .tuple #[key, value, tail]) (.atom "none")) entries := by
  induction entries with
  | nil => exact .empty
  | cons pair rest ih => exact .next ih

theorem new_iterator_preserves_visible_map (entries : List (Term × Term)) :
    ∃ result, Erlang.maps.«next/1» (.cons (.integer 0) (.map entries)) = .ok result ∧
      IteratorContents result (Term.mapEntries entries) := by
  exact ⟨_, rfl, iterator_all_entries _⟩

theorem empty_keyword_search (key : Term) (index : Int) (positive : 0 < index) :
    Erlang.lists.«keyfind/3» key (.integer index) .nil = .ok Term.false := by
  simp [Erlang.lists.«keyfind/3», positive]

-- An unsupported search cannot supply a successful precondition.
theorem unmodeled_keyword_search_fails (key index head tail : Term) :
    Erlang.lists.«keyfind/3» key index (.cons head tail) = .error .exhausted := by
  cases index <;> rfl
end Ankole.RuntimeSupport
