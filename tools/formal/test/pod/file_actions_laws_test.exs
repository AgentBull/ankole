defmodule Ankole.Formal.Pod.FileActionsLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Pod.Files

  defp public_asset?(path), do: String.starts_with?(path, ["dist/", "assets/"])
  defp private_source?(path), do: String.starts_with?(path, ["src/", "server/"])

  laws "Applet file action boundary" do
    prelude(~LEAN"""
    module
    public import Lynx
    import all Lynx.Term.Compare
    @[expose] public section
    namespace FileActionProof
    @[simp] theorem compare_atoms (a b : String) :
        Lynx.Term.compare (.atom a) (.atom b) = compare a b := by
      rw [Lynx.Term.compare_eq_step]
      rfl
    end FileActionProof
    """)

    cutoff(&IO.warn/1)
    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.predicate_range/5)
    cutoff(&:binary.compile_pattern/1)

    law(public_assets_require_view(path),
      requires: public_asset?(path),
      expects: Files.required_read_action(%{type: :applet}, path) === {:ok, "page_view"},
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «public_assets_require_view:requires/1», «public_asset?/1»] at requires
      simp only [Lynx.apply_eq, «public_assets_require_view:ensures/1»]
      unfold Elixir.Ankole.Pod.Files.«required_read_action/2»
      dsimp only
      simp [Lynx.Term.getMapKeys, requires, Erlang.erlang.«=:=/2»,
        Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Lynx.Except.andAlso, Lynx.Except.tryWith_ok, Erlang.erlang.«/=/2», Std.ReflCmp.compare_self]
      """
    )

    law(private_sources_require_edit(path),
      requires: not public_asset?(path) and private_source?(path),
      expects: Files.required_read_action(%{type: :applet}, path) === {:ok, "page_edit"},
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «private_sources_require_edit:requires/1», «public_asset?/1», «private_source?/1»] at requires
      simp only [Lynx.Except.bind_eq_ok] at requires
      obtain ⟨publicFlag, hp, requires⟩ := requires
      cases publicFlag <;> simp [Erlang.erlang.«not/1», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind] at requires
      split at requires <;> simp_all
      simp only [Lynx.apply_eq, «private_sources_require_edit:ensures/1»]
      unfold Elixir.Ankole.Pod.Files.«required_read_action/2»
      dsimp only
      simp [Lynx.Term.getMapKeys, hp, requires, Erlang.erlang.«=:=/2»,
        Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Lynx.Except.andAlso, Lynx.Except.tryWith_ok, Erlang.erlang.«/=/2», Std.ReflCmp.compare_self]
      """
    )
  end

  test "normalized Applet paths preserve the view and edit boundary" do
    for path <- ["dist/index.html", "assets/a.png"],
        do: assert(Files.required_read_action(%{type: :applet}, path) == {:ok, "page_view"})

    for path <- ~w(src/main.ts server/main.ts package.json bun.lock tsconfig.json applet.env.json),
        do: assert(Files.required_read_action(%{type: :applet}, path) == {:ok, "page_edit"})

    for path <- ["dist/../server/main.ts", "assets//x", "/dist/x", "src/./secret"],
        do: assert(match?({:error, _}, Ankole.Files.Path.normalize(path)))
  end
end
