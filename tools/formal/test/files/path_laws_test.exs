defmodule Ankole.Formal.Files.PathLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Files.Path, as: DrivePath

  laws "Successful path validation" do
    cutoff(&Enumerable.reduce/3)
    cutoff(&Enum.reduce_range/5)
    cutoff(&Enum.predicate_range/5)
    cutoff(&Regex.split/3)
    cutoff(&String.split_empty/3)
    cutoff(&String.split_each/4)
    cutoff(&:binary.compile_pattern/1)

    law(successful_normalization_respects_utf8_and_budget(path),
      requires: match?({:ok, _}, DrivePath.normalize(path)),
      expects:
        is_binary(path) and String.valid?(path) and byte_size(path) >= 1 and
          byte_size(path) <= 1024,
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «successful_normalization_respects_utf8_and_budget:requires/1»] at requires
      unfold Elixir.Ankole.Files.Path.«normalize/1» at requires
      dsimp only at requires
      simp only [bind_assoc] at requires
      cases path <;> simp [Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind] at requires
      rename_i bytes trailing valid
      rcases trailing with ⟨trailing, bound⟩
      cases trailing
      next =>
        try dsimp only at requires
        rw [Lynx.Except.bind_eq_ok] at requires
        obtain ⟨segments, hs, requires⟩ := requires
        split at hs
        next =>
          simp only [Lynx.Except.bind_eq_ok] at hs
          rcases hs with ⟨parts, hparts, utf8, hutf8, rest⟩
          rcases rest with ⟨budget, hb, noNul, hn, allValid, ha, hout⟩
          have budgetTrue : budget = Lynx.Term.true := by
            split at hn
            next =>
              simp only [Except.ok.injEq] at hn
              subst noNul
              simp only [Except.ok.injEq] at ha
              subst allValid
              simp [Lynx.Term.isMember, Lynx.Except.guard] at hout
              subst segments
              simp at requires
            next => rfl
            next => simp at hn
          subst budget
          split at hb <;> simp_all [«successful_normalization_respects_utf8_and_budget:ensures/1»,
            Erlang.erlang.«is_binary/1», Erlang.erlang.«byte_size/1», Erlang.erlang.«is_integer/1»,
            Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
            Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind] <;> split at hb <;> simp_all
        next => simp_all
      next => simp at requires
      """
    )
  end

  test "valid production paths satisfy the conditional law's premise" do
    for path <- ["assets/x", "src/main.ts", "文件/图片.png", String.duplicate("a", 255)] do
      assert DrivePath.normalize(path) == {:ok, path}
    end
  end
end
