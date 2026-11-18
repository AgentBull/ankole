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

    # `normalize/1` first applies NFC through `:unicode.characters_to_nfc_binary/1`,
    # which Lynx cannot translate, so the law covers the check on its NFC output.
    law(valid_paths_respect_utf8_and_budget(path),
      requires: is_binary(path) and DrivePath.valid_path?(path),
      expects:
        is_binary(path) and String.valid?(path) and byte_size(path) >= 1 and
          byte_size(path) <= 1024,
      proof: ~LEAN"""
      simp only [Lynx.apply_eq, «valid_paths_respect_utf8_and_budget:requires/1»] at requires
      simp only [«valid_paths_respect_utf8_and_budget:ensures/1»]
      unfold Elixir.Ankole.Files.Path.«valid_path?/1» at requires
      cases path <;> simp [Erlang.erlang.«is_binary/1», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind] at requires ⊢
      rename_i bytes trailing valid
      rcases trailing with ⟨trailing, bound⟩
      cases trailing
      next =>
        simp only [Fin.zero_eta, Fin.mk_zero] at requires ⊢
        cases hv : Elixir.String.«valid?/1» (Lynx.Term.bitstring bytes 0 valid) with
        | error e => simp [hv] at requires
        | ok v =>
          simp [hv] at requires ⊢
          split at requires <;> by_cases h1 : 1 ≤ (bytes.size : Int) <;>
            by_cases h2 : (bytes.size : Int) ≤ 1024 <;>
            simp_all [Erlang.erlang.«byte_size/1», Erlang.erlang.«is_integer/1»,
              Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
              Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind]
      next => simp at requires
      """
    )
  end

  test "valid production paths are NFC and satisfy the law" do
    for path <- ["assets/x", "src/main.ts", "文件/图片.png", String.duplicate("a", 255)] do
      assert DrivePath.normalize(path) == {:ok, path}
      assert valid_paths_respect_utf8_and_budget(path)
    end

    assert DrivePath.normalize("cafe\u0301.txt") == {:ok, "café.txt"}
  end
end
