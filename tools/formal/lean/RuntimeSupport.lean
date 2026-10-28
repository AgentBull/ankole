module
public import Lynx.Modules.Erlang.maps
public import Lynx.Modules.Erlang.lists
public import Lynx.Modules.Elixir.Access
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
theorem keys_preserve_iterator_entries (entries : List (Term × Term)) :
    Erlang.maps.«keys/1» (.map entries) =
      .ok (Term.list ((Term.mapEntries entries).map Prod.fst)) := rfl

theorem access_plain_map (entries : List (Term × Term)) (key fallback : Term)
    (plain : Term.mapLookup entries (.atom "__struct__") = none) :
    Elixir.Access.«get/3» (.map entries) key fallback =
      .ok ((Term.mapLookup entries key).getD fallback) := by
  simp [Elixir.Access.«get/3», plain]

theorem access_default_is_nil (container key : Term) :
    Elixir.Access.«get/2» container key = Elixir.Access.«get/3» container key (.atom "nil") := rfl

theorem access_nil (key fallback : Term) :
    Elixir.Access.«get/3» (.atom "nil") key fallback = .ok fallback := rfl

theorem unmodeled_struct_access_fails (entries : List (Term × Term)) (key fallback tag : Term)
    (struct : Term.mapLookup entries (.atom "__struct__") = some tag) :
    Elixir.Access.«get/3» (.map entries) key fallback = .error .exhausted := by
  simp [Elixir.Access.«get/3», struct]
end Ankole.RuntimeSupport
