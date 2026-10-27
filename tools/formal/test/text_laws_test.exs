defmodule Ankole.Formal.TextLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Text

  defp valid_prefix_result?(text, max_bytes, out) do
    is_binary(out) and
      String.valid?(out) and
      byte_size(out) <= max_bytes and
      byte_size(out) <= byte_size(text) and
      binary_part(text, 0, byte_size(out)) == out
  end

  defp valid_suffix_result?(text, max_bytes, out) do
    is_binary(out) and
      String.valid?(out) and
      byte_size(out) <= max_bytes and
      byte_size(out) <= byte_size(text) and
      binary_part(text, byte_size(text) - byte_size(out), byte_size(out)) == out and
      (byte_size(text) > max_bytes or out == text)
  end

  defp valid_truncated_result?(text, max_bytes, out) do
    is_binary(out) and
      String.valid?(out) and
      byte_size(out) <= max_bytes and
      (byte_size(text) > max_bytes or out == text)
  end

  laws "UTF-8 byte budget contracts" do
    prelude(~LEAN"""
    module

    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Bitstring.Matching
    import all Lynx.Term.Compare

    @[expose] public section

    namespace TextProof
    open Lynx

    abbrev bin (bs : List UInt8) : Term :=
      .bitstring ⟨bs.toArray⟩ 0 (Term.Bitstring.valid_aligned _)

    theorem bin_of_is_binary {t : Term}
        (h : Erlang.erlang.«is_binary/1» t = .ok Term.true) :
        ∃ bs : List UInt8, t = bin bs := by
      cases t with
      | bitstring bytes last valid =>
        rcases last with ⟨_ | n, hn⟩
        · rcases bytes with ⟨⟨bs⟩⟩
          exact ⟨bs, rfl⟩
        · simp [Erlang.erlang.«is_binary/1», Fin.ext_iff] at h
      | _ => simp [Erlang.erlang.«is_binary/1»] at h

    theorem nat_of_nonneg_int {t : Term}
        (hi : Erlang.erlang.«is_integer/1» t = .ok Term.true)
        (hge : Erlang.erlang.«>=/2» t (.integer 0) = .ok Term.true) :
        ∃ m : Nat, t = .integer m := by
      cases t with
      | integer z =>
        simp [Erlang.erlang.«>=/2_integers»] at hge
        exact ⟨z.toNat, by congr 1; omega⟩
      | _ => simp [Erlang.erlang.«is_integer/1»] at hi

    @[simp] theorem is_binary_bin (bs : List UInt8) :
        Erlang.erlang.«is_binary/1» (bin bs) = .ok Term.true := rfl

    @[simp] theorem byte_size_bin (bs : List UInt8) :
        Erlang.erlang.«byte_size/1» (bin bs) = .ok (.integer bs.length) := by
      simp [bin, Erlang.erlang.«byte_size/1», ByteArray.size]

    @[simp] theorem binarySegment_bin (bs : List UInt8) :
        Term.Bitstring.binarySegment (bin bs) (.atom "all") 8 = .ok (bin bs) :=
      Term.Bitstring.binarySegment_aligned ⟨bs.toArray⟩

    @[simp] theorem append_bin (left right : List UInt8) :
        Term.Bitstring.append (bin left) (bin right) = .ok (bin (left ++ right)) :=
      Term.Bitstring.append_bytes left right

    @[simp] theorem matchTail_bin8 (bs : List UInt8) :
        Term.Bitstring.matchTail (bin bs) (.atom "all") 8 = Bool.true := by
      simp [bin, Term.Bitstring.matchTail, Term.Bitstring.bitSize]
      split <;> omega

    @[simp] theorem eq_self_term (t : Term) :
        Erlang.erlang.«==/2» t t = .ok Term.true := by
      simp [Erlang.erlang.«==/2», Std.ReflCmp.compare_self]

    @[simp] theorem min_integers (x y : Int) :
        Erlang.erlang.«min/2» (.integer x) (.integer y) =
          .ok (.integer (if x ≤ y then x else y)) := by
      by_cases h : x ≤ y <;> simp [Erlang.erlang.«min/2», Int.isLE_compare, h]

    @[simp] theorem max_integers (x y : Int) :
        Erlang.erlang.«max/2» (.integer x) (.integer y) =
          .ok (.integer (if y ≤ x then x else y)) := by
      by_cases h : y ≤ x <;> simp [Erlang.erlang.«max/2», Int.isGE_compare, h]

    @[simp] theorem gt_integers (x y : Int) :
        Erlang.erlang.«>/2» (.integer x) (.integer y) =
          .ok (if y < x then Term.true else Term.false) := by
      by_cases h : y < x <;>
        simp [Erlang.erlang.«>/2», Ordering.isGT_iff_eq_gt, Int.compare_eq_gt, h]

    @[simp] theorem div2_nat (n : Nat) :
        Erlang.erlang.«div/2» (.integer (n : Int)) (.integer 2) =
          .ok (.integer ((n / 2 : Nat) : Int)) := rfl

    @[simp] theorem exactCompare_atom (a : Term) (name : String) :
        (Term.exactCompare a (.atom name) = .eq) ↔ a = .atom name := by
      cases a <;> rw [Term.exactCompare_eq_step] <;> simp [Term.Compare.compareStep]

    @[simp] theorem isMember_true_falsy :
        Term.isMember Term.true [Term.atom "false", Term.atom "nil"] = Term.false := by
      simp [Term.isMember, Term.true, Term.false]

    @[simp] theorem isMember_false_falsy :
        Term.isMember Term.false [Term.atom "false", Term.atom "nil"] = Term.true := by
      simp [Term.isMember, Term.true, Term.false]

    theorem extract_list (bs : List UInt8) (pos len : Nat) (h : pos + len ≤ bs.length) :
        (ByteArray.mk bs.toArray).extract pos (pos + len) =
          ByteArray.mk ((bs.drop pos).take len).toArray := by
      ext i h1 h2 <;> (simp; try omega)

    theorem binary_part_bin (bs : List UInt8) (pos len : Nat) (h : pos + len ≤ bs.length) :
        Erlang.erlang.«binary_part/3» (bin bs) (.integer pos) (.integer len) =
          .ok (bin ((bs.drop pos).take len)) := by
      have hnonneg : ¬ ((len : Int) < 0) := by omega
      have hbounds : (0 : Int) ≤ pos ∧ (pos : Int) ≤ (pos : Int) + len ∧
          (pos : Int) + len ≤ ((ByteArray.mk bs.toArray).size : Int) := by
        simp [ByteArray.size]; omega
      have hpos : (pos : Int).toNat = pos := by omega
      have hstop : ((pos : Int) + len).toNat = pos + len := by omega
      simp only [bin, Erlang.erlang.«binary_part/3», hnonneg, ↓reduceIte, hbounds, and_self,
        hpos, hstop, extract_list bs pos len h]

    theorem binary_part_zero (bs : List UInt8) (len : Nat) (h : len ≤ bs.length) :
        Erlang.erlang.«binary_part/3» (bin bs) (.integer 0) (.integer len) =
          .ok (bin (bs.take len)) := by
      simpa using binary_part_bin bs 0 len (by omega)

    theorem binary_part_one (bs : List UInt8) (len : Nat) (h : 1 + len ≤ bs.length) :
        Erlang.erlang.«binary_part/3» (bin bs) (.integer 1) (.integer len) =
          .ok (bin ((bs.drop 1).take len)) := by
      simpa using binary_part_bin bs 1 len h

    theorem bin_cons_ne_empty (b : UInt8) (rest : List UInt8) (v) :
        bin (b :: rest) ≠ .bitstring ⟨⟨[]⟩⟩ 0 v := by
      intro h
      have h2 : ((b :: rest).toArray).toList = ([] : List UInt8) := by
        cases h
      simp at h2

    theorem matchUtf8_rest_matchTail {t v rest : Term}
        (h : Term.Bitstring.matchUtf8 t = some (v, rest)) :
        Term.Bitstring.matchTail rest (.atom "all") 1 = Bool.true := by
      unfold Term.Bitstring.matchUtf8 at h
      split at h
      · simp only [Option.ite_none_right_eq_some, Option.some.injEq, Prod.mk.injEq] at h
        rcases h with ⟨_, _, rfl⟩
        exact Term.Bitstring.matchTail_bits _
      · contradiction

    def validUtf8Term (t : Term) : Bool :=
      match h : Term.Bitstring.matchUtf8 t with
      | some (_, rest) =>
        if Term.Bitstring.matchTail rest (.atom "all") 1 then validUtf8Term rest else Bool.false
      | none => Term.Bitstring.matchEnd t
    termination_by sizeOf t
    decreasing_by
      have := Term.Bitstring.matchUtf8_sizeOf h
      omega

    theorem validUtf8Term_of_none {t : Term} (hm : Term.Bitstring.matchUtf8 t = none) :
        validUtf8Term t = Term.Bitstring.matchEnd t := by
      rw [validUtf8Term.eq_def]
      split
      · rename_i _ _ h; rw [hm] at h; cases h
      · rfl

    theorem validUtf8Term_of_some {t v rest : Term}
        (hm : Term.Bitstring.matchUtf8 t = some (v, rest)) :
        validUtf8Term t = validUtf8Term rest := by
      have htail := matchUtf8_rest_matchTail hm
      rw [validUtf8Term.eq_def]
      split
      · rename_i _ rest' h
        rw [hm] at h
        injection h with hpair
        injection hpair with _ hrest
        subst hrest
        simp [htail]
      · rename_i h; rw [hm] at h; cases h

    theorem validUtf8Term_nil : validUtf8Term (bin []) = Bool.true := by
      have hm : Term.Bitstring.matchUtf8 (bin []) = none := by
        simp [bin, Term.Bitstring.matchUtf8, Term.Bitstring.toBits_bytes,
          Term.Bitstring.decodeInteger]
      rw [validUtf8Term_of_none hm]
      exact Term.Bitstring.matchEnd_byte_nil

    private theorem flatMap_byte_length (bs : List UInt8) :
        (bs.flatMap fun b => (List.range 8).map fun j => b.toBitVec.getMsbD j).length =
          bs.length * 8 := by
      induction bs with
      | nil => rfl
      | cons _ rest ih => simp [List.flatMap_cons, ih]; omega

    private theorem ofBits_drop_bytes (bs : List UInt8) (k : Nat) :
        Term.Bitstring.ofBits
          (((bs.flatMap fun b => (List.range 8).map fun j => b.toBitVec.getMsbD j)).drop (k * 8)) =
          bin (bs.drop k) := by
      rw [Term.Bitstring.drop_bytes, ← Term.Bitstring.toBits_bytes,
        Term.Bitstring.ofBits_toBits_aligned]

    private theorem getD_append_left (bs1 bs2 : List UInt8) (k : Nat) (hk : k < bs1.length) :
        (bs1 ++ bs2).getD k 0 = bs1.getD k 0 := by
      simp [List.getD_eq_getElem?_getD, List.getElem?_append_left hk]

    theorem matchUtf8_append_of_some {bs1 : List UInt8} (bs2 : List UInt8) {v rest : Term}
        (h : Term.Bitstring.matchUtf8 (bin bs1) = some (v, rest)) :
        ∃ count : Nat, 1 ≤ count ∧ count ≤ bs1.length ∧
          rest = bin (bs1.drop count) ∧
          Term.Bitstring.matchUtf8 (bin (bs1 ++ bs2)) =
            some (v, bin (bs1.drop count ++ bs2)) := by
      simp only [bin, Term.Bitstring.matchUtf8, Term.Bitstring.toBits_bytes,
        Term.Bitstring.byte_at, flatMap_byte_length, ofBits_drop_bytes] at h ⊢
      generalize hc1 :
        (if (bs1.getD 0 0).toNat < 128 then 1
         else if 194 ≤ (bs1.getD 0 0).toNat ∧ (bs1.getD 0 0).toNat ≤ 223 then 2
         else if 224 ≤ (bs1.getD 0 0).toNat ∧ (bs1.getD 0 0).toNat ≤ 239 then 3
         else if 240 ≤ (bs1.getD 0 0).toNat ∧ (bs1.getD 0 0).toNat ≤ 244 then 4 else 0) = count1 at h
      simp only [Option.ite_none_right_eq_some, Option.some.injEq, Prod.mk.injEq] at h
      rcases h with ⟨⟨hne0, hlen8, hall, hmin, hmax, hscalar⟩, rfl, rfl⟩
      have hcount_cases : count1 = 1 ∨ count1 = 2 ∨ count1 = 3 ∨ count1 = 4 := by
        revert hc1
        split
        · intro hc1; omega
        · split
          · intro hc1; omega
          · split
            · intro hc1; omega
            · split <;> (intro hc1; omega)
      have hcount_pos : 1 ≤ count1 := by omega
      have hcount_le : count1 ≤ bs1.length := by omega
      refine ⟨count1, hcount_pos, hcount_le, rfl, ?_⟩
      have h0 : (bs1 ++ bs2).getD 0 0 = bs1.getD 0 0 := getD_append_left bs1 bs2 0 (by omega)
      have hdrop : (bs1 ++ bs2).drop count1 = bs1.drop count1 ++ bs2 :=
        List.drop_append_of_le_length hcount_le
      have hlen_app : count1 * 8 ≤ (bs1 ++ bs2).length * 8 := by simp; omega
      simp only [h0, hc1, hdrop]
      rcases hcount_cases with rfl | rfl | rfl | rfl
      · simp at hmin hmax hscalar ⊢
        omega
      · have h1 : (bs1 ++ bs2).getD 1 0 = bs1.getD 1 0 := getD_append_left bs1 bs2 1 (by omega)
        have hr1 : List.range (2 - 1) = [0] := rfl
        simp only [hr1, List.foldl, List.all, Nat.zero_add, h1] at hall hmin hmax hscalar ⊢
        simp at hall hmin hmax hscalar ⊢
        omega
      · have h1 : (bs1 ++ bs2).getD 1 0 = bs1.getD 1 0 := getD_append_left bs1 bs2 1 (by omega)
        have h2 : (bs1 ++ bs2).getD 2 0 = bs1.getD 2 0 := getD_append_left bs1 bs2 2 (by omega)
        have hr2 : List.range (3 - 1) = [0, 1] := rfl
        simp only [hr2, List.foldl, List.all, Nat.zero_add, Nat.reduceAdd, h1, h2] at hall hmin hmax hscalar ⊢
        simp at hall hmin hmax hscalar ⊢
        omega
      · have h1 : (bs1 ++ bs2).getD 1 0 = bs1.getD 1 0 := getD_append_left bs1 bs2 1 (by omega)
        have h2 : (bs1 ++ bs2).getD 2 0 = bs1.getD 2 0 := getD_append_left bs1 bs2 2 (by omega)
        have h3 : (bs1 ++ bs2).getD 3 0 = bs1.getD 3 0 := getD_append_left bs1 bs2 3 (by omega)
        have hr3 : List.range (4 - 1) = [0, 1, 2] := rfl
        simp only [hr3, List.foldl, List.all, Nat.zero_add, Nat.reduceAdd, h1, h2, h3] at hall hmin hmax hscalar ⊢
        simp at hall hmin hmax hscalar ⊢
        omega

    theorem validUtf8Term_append :
        ∀ (a b : List UInt8),
          validUtf8Term (bin a) = Bool.true →
          validUtf8Term (bin b) = Bool.true →
          validUtf8Term (bin (a ++ b)) = Bool.true := by
      intro a
      suffices ∀ n (a b : List UInt8), a.length ≤ n →
          validUtf8Term (bin a) = Bool.true →
          validUtf8Term (bin b) = Bool.true →
          validUtf8Term (bin (a ++ b)) = Bool.true by
        exact fun b ha hb => this a.length a b (Nat.le_refl _) ha hb
      intro n
      induction n with
      | zero =>
        intro a b hlen _ hb
        have ha_nil : a = [] := List.eq_nil_of_length_eq_zero (by omega)
        subst ha_nil
        simpa using hb
      | succ n ih =>
        intro a b hlen ha hb
        rcases a with _ | ⟨x, xs⟩
        · simpa using hb
        · cases hm : Term.Bitstring.matchUtf8 (bin (x :: xs)) with
          | none =>
            rw [validUtf8Term_of_none hm] at ha
            simp [bin, Term.Bitstring.matchEnd_byte] at ha
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [validUtf8Term_of_some hm] at ha
            obtain ⟨count, hpos, hcle, rfl, hm_app⟩ := matchUtf8_append_of_some b hm
            rw [validUtf8Term_of_some hm_app]
            exact ih ((x :: xs).drop count) b (by simp at hlen ⊢; omega) ha hb

    def trimSuffixBytes (bs : List UInt8) : List UInt8 :=
      if bs.isEmpty then []
      else if validUtf8Term (bin bs) then bs
      else trimSuffixBytes (bs.take (bs.length - 1))
    termination_by bs.length
    decreasing_by
      cases bs with
      | nil => simp at *
      | cons _ rest => simp

    theorem trimSuffixBytes_spec :
        ∀ (bs : List UInt8),
          validUtf8Term (bin (trimSuffixBytes bs)) = Bool.true ∧
          (trimSuffixBytes bs).length ≤ bs.length ∧
          bs.take (trimSuffixBytes bs).length = trimSuffixBytes bs := by
      intro bs
      suffices ∀ n (bs : List UInt8), bs.length ≤ n →
          validUtf8Term (bin (trimSuffixBytes bs)) = Bool.true ∧
          (trimSuffixBytes bs).length ≤ bs.length ∧
          bs.take (trimSuffixBytes bs).length = trimSuffixBytes bs by
        exact this bs.length bs (Nat.le_refl _)
      intro n
      induction n with
      | zero =>
        intro bs hlen
        have hbs : bs = [] := List.eq_nil_of_length_eq_zero (by omega)
        subst hbs
        rw [trimSuffixBytes.eq_def]
        simp [validUtf8Term_nil]
      | succ n ih =>
        intro bs hlen
        rcases bs with _ | ⟨b, rest⟩
        · rw [trimSuffixBytes.eq_def]
          simp [validUtf8Term_nil]
        · rw [trimSuffixBytes.eq_def]
          simp only [List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte]
          by_cases hv : validUtf8Term (bin (b :: rest)) = Bool.true
          · simp [hv]
          · simp only [hv, Bool.false_eq_true, ↓reduceIte, List.length_cons, Nat.add_sub_cancel]
            have hsub : ((b :: rest).take rest.length).length ≤ n := by
              simp only [List.length_cons] at hlen
              simp; omega
            obtain ⟨hval, hle, hpre⟩ := ih ((b :: rest).take rest.length) hsub
            refine ⟨hval, by simp at hle ⊢; omega, ?_⟩
            rw [List.take_take] at hpre
            have hmin : min (trimSuffixBytes ((b :: rest).take rest.length)).length rest.length =
                (trimSuffixBytes ((b :: rest).take rest.length)).length := by
              simp at hle; omega
            rwa [hmin] at hpre

    theorem trimSuffixBytes_of_valid {bs : List UInt8}
        (hv : validUtf8Term (bin bs) = Bool.true) :
        trimSuffixBytes bs = bs := by
      rw [trimSuffixBytes.eq_def]
      cases bs <;> simp [hv]

    def trimPrefixBytes : List UInt8 → List UInt8
      | [] => []
      | b :: rest =>
        if validUtf8Term (bin (b :: rest)) then b :: rest
        else trimPrefixBytes rest

    theorem trimPrefixBytes_spec (bs : List UInt8) :
        validUtf8Term (bin (trimPrefixBytes bs)) = Bool.true ∧
        (trimPrefixBytes bs).length ≤ bs.length ∧
        bs.drop (bs.length - (trimPrefixBytes bs).length) = trimPrefixBytes bs := by
      induction bs with
      | nil =>
        simp [trimPrefixBytes, validUtf8Term_nil]
      | cons b rest ih =>
        simp only [trimPrefixBytes]
        by_cases hv : validUtf8Term (bin (b :: rest)) = Bool.true
        · simp [hv]
        · simp only [hv, Bool.false_eq_true, ↓reduceIte]
          obtain ⟨hval, hle, hsuf⟩ := ih
          refine ⟨hval, by simp; omega, ?_⟩
          have hsub : (b :: rest).length - (trimPrefixBytes rest).length =
              (rest.length - (trimPrefixBytes rest).length) + 1 := by
            simp; omega
          rw [hsub, List.drop_succ_cons]
          exact hsuf

    end TextProof
    """)

    termination_suffix(&Text.trim_invalid_utf8_prefix/1, ~LEAN"partial_fixpoint")
    termination_suffix(&Text.trim_invalid_utf8_suffix/1, ~LEAN"partial_fixpoint")

    law(utf8_prefix_universal_contract(text, max_bytes),
      requires: is_binary(text) and is_integer(max_bytes) and max_bytes >= 0,
      expects: valid_prefix_result?(text, max_bytes, Text.utf8_prefix(text, max_bytes)),
      proof: ~LEAN"""
      rw [«utf8_prefix_universal_contract:requires/2»] at requires
      rw [«utf8_prefix_universal_contract:ensures/2»]
      have hreq :
          Erlang.erlang.«is_binary/1» text = .ok .true ∧
          Erlang.erlang.«is_integer/1» max_bytes = .ok .true ∧
          Erlang.erlang.«>=/2» max_bytes (.integer 0) = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» text with
        | error e => simp [hb] at requires
        | ok vb =>
          cases vb with
          | atom sb =>
            by_cases hsb : sb = "true"
            · subst hsb
              cases hi : Erlang.erlang.«is_integer/1» max_bytes with
              | error e => simp [hb, hi] at requires
              | ok vi =>
                cases vi with
                | atom si =>
                  by_cases hsi : si = "true"
                  · subst hsi
                    simp [hb, hi] at requires
                    exact ⟨rfl, rfl, requires⟩
                  · by_cases hsf : si = "false"
                    · subst hsf; simp [hb, hi] at requires
                    · simp [hb, hi, hsi, hsf] at requires
                | _ => simp [hb, hi] at requires
            · by_cases hsf : sb = "false"
              · subst hsf; simp [hb] at requires
              · simp [hb, hsb, hsf] at requires
          | _ => simp [hb] at requires
      obtain ⟨bs, rfl⟩ := TextProof.bin_of_is_binary hreq.1
      obtain ⟨m, rfl⟩ := TextProof.nat_of_nonneg_int hreq.2.1 hreq.2.2
      clear requires hreq
      have hvalid_utf8 : ∀ t : Lynx.Term,
          Elixir.String.«valid_utf8?/1» t =
            .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) := by
        intro t
        suffices ∀ n (t : Lynx.Term), sizeOf t ≤ n →
            Elixir.String.«valid_utf8?/1» t =
              .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) by
          exact this (sizeOf t) t (Nat.le_refl _)
        intro n
        induction n with
        | zero =>
          intro t hsz
          cases t <;> simp at hsz
        | succ n ih =>
          intro t hsz
          rw [Elixir.String.«valid_utf8?/1».eq_def]
          cases hm : Lynx.Term.Bitstring.matchUtf8 t with
          | none =>
            rw [TextProof.validUtf8Term_of_none hm]
            cases he : Lynx.Term.Bitstring.matchEnd t <;> simp [hm, he, Lynx.Term.true, Lynx.Term.false]
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [TextProof.validUtf8Term_of_some hm]
            have htail := TextProof.matchUtf8_rest_matchTail hm
            have hlt := Lynx.Term.Bitstring.matchUtf8_sizeOf hm
            simp only [hm, Lynx.Term.Bitstring.extract_some, htail, ↓reduceIte]
            exact ih rest (by omega)
      have hvalid_bin : ∀ xs : List UInt8,
          Elixir.String.«valid?/1» (TextProof.bin xs) =
            .ok (if TextProof.validUtf8Term (TextProof.bin xs) then Lynx.Term.true else Lynx.Term.false) := by
        intro xs
        simp [Elixir.String.«valid?/1», Elixir.String.«valid?/2», hvalid_utf8]
      have htrim_suf : ∀ xs : List UInt8,
          Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
            .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) := by
        intro xs
        suffices ∀ n (xs : List UInt8), xs.length ≤ n →
            Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
              .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) by
          exact this xs.length xs (Nat.le_refl _)
        intro n
        induction n with
        | zero =>
          intro xs hlen
          have hnil : xs = [] := List.eq_nil_of_length_eq_zero (by omega)
          subst hnil
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
          rfl
        | succ n ih =>
          intro xs hlen
          rcases xs with _ | ⟨b, rest⟩
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            rfl
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            split
            · rename_i v heq
              exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
            · simp only [List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte, hvalid_bin]
              by_cases hv : TextProof.validUtf8Term (TextProof.bin (b :: rest)) = Bool.true
              · simp [hv, Lynx.Except.guard]
              · simp only [hv, Bool.false_eq_true, ↓reduceIte, TextProof.isMember_false_falsy, Lynx.Except.guard,
                  Lynx.Except.tryWith_ok, Lynx.Term.true, TextProof.byte_size_bin, List.length_cons,
                  Erlang.erlang.«-/2_integers», Lynx.Except.bindReturned]
                have hsub : (((rest.length + 1 : Nat) : Int) - 1) = (rest.length : Int) := by omega
                rw [hsub, Nat.add_sub_cancel]
                erw [TextProof.binary_part_zero (b :: rest) rest.length (by simp)]
                simp only [Lynx.Except.bindReturned]
                apply ih ((b :: rest).take rest.length)
                simp only [List.length_cons, List.length_take] at hlen ⊢
                omega
      let k := min bs.length m
      have hk_eq : (if (bs.length : Int) ≤ (m : Int) then (bs.length : Int) else (m : Int)) = (k : Int) := by
        dsimp [k]; split <;> omega
      have hprefix : Elixir.Ankole.Text.«utf8_prefix/2» (TextProof.bin bs) (.integer m) =
          .ok (TextProof.bin (TextProof.trimSuffixBytes (bs.take k))) := by
        simp only [Elixir.Ankole.Text.«utf8_prefix/2», Lynx.Except.andAlso_eq,
          TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
          Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
          TextProof.byte_size_bin, TextProof.min_integers, hk_eq, Lynx.Except.bindReturned]
        rw [TextProof.binary_part_zero bs k (by dsimp [k]; omega)]
        simp only [Lynx.Except.bindReturned, htrim_suf]
      obtain ⟨hout_val, hout_le_k, hout_take⟩ := TextProof.trimSuffixBytes_spec (bs.take k)
      generalize hout_eq : TextProof.trimSuffixBytes (bs.take k) = out at *
      have htk_le_k : (bs.take k).length ≤ k := by simp [List.length_take]; omega
      have htk_le_bs : (bs.take k).length ≤ bs.length := by simp [List.length_take]; omega
      have hk_le_m : k ≤ m := Nat.min_le_right bs.length m
      have hout_le_m : out.length ≤ m := by omega
      have hout_le_bs : out.length ≤ bs.length := by omega
      have hbs_take_out : bs.take out.length = out := by
        rw [List.take_take] at hout_take
        have hmin : min out.length k = out.length := by omega
        rwa [hmin] at hout_take
      have hbp_out : Erlang.erlang.«binary_part/3» (TextProof.bin bs) (.integer 0) (.integer out.length) =
          .ok (TextProof.bin out) := by
        rw [TextProof.binary_part_zero bs out.length hout_le_bs]
        simp [hbs_take_out]
      rw [hprefix]
      simp [Lynx.Except.bindReturned, «valid_prefix_result?/3», Lynx.Term.true, Lynx.Term.false,
        hvalid_bin, hout_val, hout_le_m, hout_le_bs, hbp_out]
      """
    )

    law(utf8_prefix_preserves_valid_within_budget(text, max_bytes),
      requires:
        is_binary(text) and String.valid?(text) and is_integer(max_bytes) and
          max_bytes >= byte_size(text),
      expects: Text.utf8_prefix(text, max_bytes) == text,
      proof: ~LEAN"""
      rw [«utf8_prefix_preserves_valid_within_budget:requires/2»] at requires
      rw [«utf8_prefix_preserves_valid_within_budget:ensures/2»]
      have hvalid_utf8 : ∀ t : Lynx.Term,
          Elixir.String.«valid_utf8?/1» t =
            .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) := by
        intro t
        suffices ∀ n (t : Lynx.Term), sizeOf t ≤ n →
            Elixir.String.«valid_utf8?/1» t =
              .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) by
          exact this (sizeOf t) t (Nat.le_refl _)
        intro n
        induction n with
        | zero => intro t hsz; cases t <;> simp at hsz
        | succ n ih =>
          intro t hsz
          rw [Elixir.String.«valid_utf8?/1».eq_def]
          cases hm : Lynx.Term.Bitstring.matchUtf8 t with
          | none =>
            rw [TextProof.validUtf8Term_of_none hm]
            cases he : Lynx.Term.Bitstring.matchEnd t <;> simp [hm, he, Lynx.Term.true, Lynx.Term.false]
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [TextProof.validUtf8Term_of_some hm]
            have htail := TextProof.matchUtf8_rest_matchTail hm
            have hlt := Lynx.Term.Bitstring.matchUtf8_sizeOf hm
            simp only [hm, Lynx.Term.Bitstring.extract_some, htail, ↓reduceIte]
            exact ih rest (by omega)
      have hbin : Erlang.erlang.«is_binary/1» text = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» text with
        | error e => simp [hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hb] at requires
              · simp [hb, hs, hf] at requires
          | _ => simp [hb] at requires
      obtain ⟨bs, rfl⟩ := TextProof.bin_of_is_binary hbin
      have hvalid_bin : ∀ xs : List UInt8,
          Elixir.String.«valid?/1» (TextProof.bin xs) =
            .ok (if TextProof.validUtf8Term (TextProof.bin xs) then Lynx.Term.true else Lynx.Term.false) := by
        intro xs
        simp [Elixir.String.«valid?/1», Elixir.String.«valid?/2», hvalid_utf8]
      have hv_bs : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true := by
        by_cases hv : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true
        · exact hv
        · simp [hvalid_bin, hv] at requires
      have hm_nat : ∃ m : Nat, max_bytes = .integer m ∧ bs.length ≤ m := by
        cases max_bytes with
        | integer z =>
          simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»] at requires
          exact ⟨z.toNat, by congr 1; omega, by omega⟩
        | _ => simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1»] at requires
      obtain ⟨m, rfl, hle⟩ := hm_nat
      clear requires hbin
      have hmin : (if (bs.length : Int) ≤ (m : Int) then (bs.length : Int) else (m : Int)) = (bs.length : Int) := by
        split <;> omega
      simp only [Elixir.Ankole.Text.«utf8_prefix/2», Lynx.Except.andAlso_eq,
        TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
        Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
        TextProof.byte_size_bin, TextProof.min_integers, hmin, Lynx.Except.bindReturned]
      rw [TextProof.binary_part_zero bs bs.length (Nat.le_refl _)]
      simp only [List.take_length, Lynx.Except.bindReturned]
      rcases bs with _ | ⟨b, rest⟩
      · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def]
        simp [Lynx.Term.true]
      · have htrim : Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin (b :: rest)) =
            .ok (TextProof.bin (b :: rest)) := by
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def]
          split
          · rename_i v heq
            exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
          · simp [hvalid_bin, hv_bs, Lynx.Except.guard, Lynx.Term.true, Lynx.Term.false]
        rw [htrim]
        simp [Lynx.Except.bindReturned, Lynx.Term.true]
      """
    )

    law(utf8_suffix_universal_contract(text, max_bytes),
      requires:
        is_binary(text) and String.valid?(text) and is_integer(max_bytes) and max_bytes >= 0,
      expects: valid_suffix_result?(text, max_bytes, Text.utf8_suffix(text, max_bytes)),
      proof: ~LEAN"""
      rw [«utf8_suffix_universal_contract:requires/2»] at requires
      rw [«utf8_suffix_universal_contract:ensures/2»]
      have hvalid_utf8 : ∀ t : Lynx.Term,
          Elixir.String.«valid_utf8?/1» t =
            .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) := by
        intro t
        suffices ∀ n (t : Lynx.Term), sizeOf t ≤ n →
            Elixir.String.«valid_utf8?/1» t =
              .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) by
          exact this (sizeOf t) t (Nat.le_refl _)
        intro n
        induction n with
        | zero => intro t hsz; cases t <;> simp at hsz
        | succ n ih =>
          intro t hsz
          rw [Elixir.String.«valid_utf8?/1».eq_def]
          cases hm : Lynx.Term.Bitstring.matchUtf8 t with
          | none =>
            rw [TextProof.validUtf8Term_of_none hm]
            cases he : Lynx.Term.Bitstring.matchEnd t <;> simp [hm, he, Lynx.Term.true, Lynx.Term.false]
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [TextProof.validUtf8Term_of_some hm]
            have htail := TextProof.matchUtf8_rest_matchTail hm
            have hlt := Lynx.Term.Bitstring.matchUtf8_sizeOf hm
            simp only [hm, Lynx.Term.Bitstring.extract_some, htail, ↓reduceIte]
            exact ih rest (by omega)
      have hvalid_bin : ∀ xs : List UInt8,
          Elixir.String.«valid?/1» (TextProof.bin xs) =
            .ok (if TextProof.validUtf8Term (TextProof.bin xs) then Lynx.Term.true else Lynx.Term.false) := by
        intro xs
        simp [Elixir.String.«valid?/1», Elixir.String.«valid?/2», hvalid_utf8]
      have hbin : Erlang.erlang.«is_binary/1» text = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» text with
        | error e => simp [hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hb] at requires
              · simp [hb, hs, hf] at requires
          | _ => simp [hb] at requires
      obtain ⟨bs, rfl⟩ := TextProof.bin_of_is_binary hbin
      have hv_bs : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true := by
        by_cases hv : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true
        · exact hv
        · simp [hvalid_bin, hv] at requires
      have hm_nat : ∃ m : Nat, max_bytes = .integer m := by
        cases max_bytes with
        | integer z =>
          simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»] at requires
          exact ⟨z.toNat, by congr 1; omega⟩
        | _ => simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1»] at requires
      obtain ⟨m, rfl⟩ := hm_nat
      clear requires hbin
      have htrim_pre : ∀ xs : List UInt8,
          Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1» (TextProof.bin xs) =
            .ok (TextProof.bin (TextProof.trimPrefixBytes xs)) := by
        intro xs
        induction xs with
        | nil =>
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1».eq_def]
          rfl
        | cons b rest ih =>
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1».eq_def]
          split
          · rename_i v heq
            exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
          · simp only [TextProof.trimPrefixBytes, hvalid_bin]
            by_cases hv : TextProof.validUtf8Term (TextProof.bin (b :: rest)) = Bool.true
            · simp [hv, Lynx.Except.guard]
            · simp only [hv, Bool.false_eq_true, ↓reduceIte, TextProof.isMember_false_falsy, Lynx.Except.guard,
                Lynx.Except.tryWith_ok, Lynx.Term.true, TextProof.byte_size_bin, List.length_cons,
                Erlang.erlang.«-/2_integers», Lynx.Except.bindReturned]
              have hsub : (((rest.length + 1 : Nat) : Int) - 1) = (rest.length : Int) := by omega
              rw [hsub]
              erw [TextProof.binary_part_one (b :: rest) rest.length (by simp; omega)]
              simp [ih]
      by_cases hle : bs.length ≤ m
      · have hle_int : (bs.length : Int) ≤ (m : Int) := by omega
        have hsuf : Elixir.Ankole.Text.«utf8_suffix/2» (TextProof.bin bs) (.integer m) =
            .ok (TextProof.bin bs) := by
          simp [Elixir.Ankole.Text.«utf8_suffix/2», hle_int, Lynx.Except.guard, Lynx.Term.true]
        have hbp : Erlang.erlang.«binary_part/3» (TextProof.bin bs)
            (.integer 0) (.integer bs.length) = .ok (TextProof.bin bs) := by
          simpa using TextProof.binary_part_zero bs bs.length (Nat.le_refl _)
        have hnot_gt : ¬ (m < bs.length) := by omega
        rw [hsuf]
        simp [Lynx.Except.bindReturned, «valid_suffix_result?/3», Lynx.Term.true, Lynx.Term.false,
          hvalid_bin, hv_bs, hle, hbp, hnot_gt]
      · have hgt : m < bs.length := by omega
        have hnot_le_int : ¬ ((bs.length : Int) ≤ (m : Int)) := by omega
        rcases m with _ | k
        · have hbs_ne : bs ≠ [] := by intro h; subst h; simp at hgt
          have hsuf0 : Elixir.Ankole.Text.«utf8_suffix/2» (TextProof.bin bs) (.integer 0) =
              .ok (TextProof.bin []) := by
            simp [Elixir.Ankole.Text.«utf8_suffix/2», hnot_le_int, hbs_ne, Lynx.Except.guard,
              Lynx.Term.true, Lynx.Term.false]
          have hbp0 : Erlang.erlang.«binary_part/3» (TextProof.bin bs)
              (.integer bs.length) (.integer 0) = .ok (TextProof.bin []) := by
            simpa using TextProof.binary_part_bin bs bs.length 0 (by omega)
          have hz : ((0 : Nat) : Int) = 0 := rfl
          rw [hz, hsuf0]
          simp [Lynx.Except.bindReturned, «valid_suffix_result?/3», Lynx.Term.true, Lynx.Term.false,
            hvalid_bin, TextProof.validUtf8Term_nil, hbp0, hgt]
        · have hk_pos : (0 : Int) < ((k + 1 : Nat) : Int) := by omega
          have hsub_int : (bs.length : Int) - ((k + 1 : Nat) : Int) = ((bs.length - (k + 1) : Nat) : Int) := by omega
          have hslice_take : ((bs.drop (bs.length - (k + 1))).take (k + 1)) = bs.drop (bs.length - (k + 1)) := by
            rw [List.take_of_length_le (by simp; omega)]
          have hsufk : Elixir.Ankole.Text.«utf8_suffix/2» (TextProof.bin bs) (.integer (k + 1 : Nat)) =
              .ok (TextProof.bin (TextProof.trimPrefixBytes (bs.drop (bs.length - (k + 1))))) := by
            unfold Elixir.Ankole.Text.«utf8_suffix/2»
            simp only [TextProof.byte_size_bin, Erlang.erlang.«=</2_integers», hnot_le_int,
              ↓reduceIte, pure, Except.pure, Lynx.Except.bindReturned, Lynx.Except.tryWith_ok,
              Lynx.Except.guard, Lynx.Term.true, Lynx.Term.false]
            split
            · simp_all
            · simp only [Lynx.Except.andAlso_eq, TextProof.is_binary_bin, TextProof.gt_integers,
                hk_pos, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
                TextProof.byte_size_bin, Erlang.erlang.«-/2_integers», hsub_int,
                Lynx.Except.bindReturned]
              rw [TextProof.binary_part_bin bs (bs.length - (k + 1)) (k + 1) (by omega)]
              simp [hslice_take, htrim_pre]
          obtain ⟨hout_val, hout_le_sl, hout_drop⟩ := TextProof.trimPrefixBytes_spec (bs.drop (bs.length - (k + 1)))
          generalize hout_eq : TextProof.trimPrefixBytes (bs.drop (bs.length - (k + 1))) = out at *
          have hsl_len : (bs.drop (bs.length - (k + 1))).length = k + 1 := by simp; omega
          have hout_le_m : out.length ≤ k + 1 := by omega
          have hout_le_bs : out.length ≤ bs.length := by omega
          have hbs_drop_out : bs.drop (bs.length - out.length) = out := by
            rw [hsl_len, List.drop_drop] at hout_drop
            have hadd : (bs.length - (k + 1)) + ((k + 1) - out.length) = bs.length - out.length := by omega
            rwa [hadd] at hout_drop
          have hsub_out : (bs.length : Int) - (out.length : Int) = ((bs.length - out.length : Nat) : Int) := by omega
          have hbp_out : Erlang.erlang.«binary_part/3» (TextProof.bin bs)
              (.integer ((bs.length : Int) - (out.length : Int))) (.integer out.length) =
              .ok (TextProof.bin out) := by
            rw [hsub_out, TextProof.binary_part_bin bs (bs.length - out.length) out.length (by omega)]
            simp [hbs_drop_out]
          have hout_le_m_int : (out.length : Int) ≤ (k : Int) + 1 := by omega
          have hgt_int : (k : Int) + 1 < (bs.length : Int) := by omega
          rw [hsufk]
          simp [Lynx.Except.bindReturned, «valid_suffix_result?/3», Lynx.Term.true, Lynx.Term.false,
            hvalid_bin, hout_val, hout_le_m_int, hout_le_bs, hbp_out, hgt_int]
      """
    )

    law(truncate_utf8_universal_contract(text, max_bytes, suffix),
      requires:
        is_binary(text) and String.valid?(text) and is_binary(suffix) and
          String.valid?(suffix) and is_integer(max_bytes) and max_bytes >= byte_size(suffix),
      expects:
        valid_truncated_result?(text, max_bytes, Text.truncate_utf8(text, max_bytes, suffix)),
      proof: ~LEAN"""
      rw [«truncate_utf8_universal_contract:requires/3»] at requires
      rw [«truncate_utf8_universal_contract:ensures/3»]
      have hvalid_utf8 : ∀ t : Lynx.Term,
          Elixir.String.«valid_utf8?/1» t =
            .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) := by
        intro t
        suffices ∀ n (t : Lynx.Term), sizeOf t ≤ n →
            Elixir.String.«valid_utf8?/1» t =
              .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) by
          exact this (sizeOf t) t (Nat.le_refl _)
        intro n
        induction n with
        | zero => intro t hsz; cases t <;> simp at hsz
        | succ n ih =>
          intro t hsz
          rw [Elixir.String.«valid_utf8?/1».eq_def]
          cases hm : Lynx.Term.Bitstring.matchUtf8 t with
          | none =>
            rw [TextProof.validUtf8Term_of_none hm]
            cases he : Lynx.Term.Bitstring.matchEnd t <;> simp [hm, he, Lynx.Term.true, Lynx.Term.false]
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [TextProof.validUtf8Term_of_some hm]
            have htail := TextProof.matchUtf8_rest_matchTail hm
            have hlt := Lynx.Term.Bitstring.matchUtf8_sizeOf hm
            simp only [hm, Lynx.Term.Bitstring.extract_some, htail, ↓reduceIte]
            exact ih rest (by omega)
      have hvalid_bin : ∀ xs : List UInt8,
          Elixir.String.«valid?/1» (TextProof.bin xs) =
            .ok (if TextProof.validUtf8Term (TextProof.bin xs) then Lynx.Term.true else Lynx.Term.false) := by
        intro xs
        simp [Elixir.String.«valid?/1», Elixir.String.«valid?/2», hvalid_utf8]
      have hbin_t : Erlang.erlang.«is_binary/1» text = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» text with
        | error e => simp [hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hb] at requires
              · simp [hb, hs, hf] at requires
          | _ => simp [hb] at requires
      obtain ⟨bs, rfl⟩ := TextProof.bin_of_is_binary hbin_t
      have hv_bs : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true := by
        by_cases hv : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true
        · exact hv
        · simp [hvalid_bin, hv] at requires
      have hbin_s : Erlang.erlang.«is_binary/1» suffix = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» suffix with
        | error e => simp [hvalid_bin, hv_bs, hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hvalid_bin, hv_bs, hb] at requires
              · simp [hvalid_bin, hv_bs, hb, hs, hf] at requires
          | _ => simp [hvalid_bin, hv_bs, hb] at requires
      obtain ⟨suf, rfl⟩ := TextProof.bin_of_is_binary hbin_s
      have hv_suf : TextProof.validUtf8Term (TextProof.bin suf) = Bool.true := by
        by_cases hv : TextProof.validUtf8Term (TextProof.bin suf) = Bool.true
        · exact hv
        · simp [hvalid_bin, hv_bs, hv] at requires
      have hm_nat : ∃ m : Nat, max_bytes = .integer m ∧ suf.length ≤ m := by
        cases max_bytes with
        | integer z =>
          simp [hvalid_bin, hv_bs, hv_suf, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»] at requires
          exact ⟨z.toNat, by congr 1; omega, by omega⟩
        | _ => simp [hvalid_bin, hv_bs, hv_suf, Erlang.erlang.«is_integer/1»] at requires
      obtain ⟨m, rfl, hsuf_le⟩ := hm_nat
      clear requires hbin_t hbin_s
      have htrim_suf : ∀ xs : List UInt8,
          Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
            .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) := by
        intro xs
        suffices ∀ n (xs : List UInt8), xs.length ≤ n →
            Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
              .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) by
          exact this xs.length xs (Nat.le_refl _)
        intro n
        induction n with
        | zero =>
          intro xs hlen
          have hnil : xs = [] := List.eq_nil_of_length_eq_zero (by omega)
          subst hnil
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
          rfl
        | succ n ih =>
          intro xs hlen
          rcases xs with _ | ⟨b, rest⟩
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            rfl
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            split
            · rename_i v heq
              exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
            · simp only [List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte, hvalid_bin]
              by_cases hv : TextProof.validUtf8Term (TextProof.bin (b :: rest)) = Bool.true
              · simp [hv, Lynx.Except.guard]
              · simp only [hv, Bool.false_eq_true, ↓reduceIte, TextProof.isMember_false_falsy, Lynx.Except.guard,
                  Lynx.Except.tryWith_ok, Lynx.Term.true, TextProof.byte_size_bin, List.length_cons,
                  Erlang.erlang.«-/2_integers», Lynx.Except.bindReturned]
                have hsub : (((rest.length + 1 : Nat) : Int) - 1) = (rest.length : Int) := by omega
                rw [hsub, Nat.add_sub_cancel]
                erw [TextProof.binary_part_zero (b :: rest) rest.length (by simp)]
                simp only [Lynx.Except.bindReturned]
                apply ih ((b :: rest).take rest.length)
                simp only [List.length_cons, List.length_take] at hlen ⊢
                omega
      by_cases hle : bs.length ≤ m
      · have hle_int : (bs.length : Int) ≤ (m : Int) := by omega
        have hnot_gt : ¬ (m < bs.length) := by omega
        have htrunc : Elixir.Ankole.Text.«truncate_utf8/3» (TextProof.bin bs) (.integer m) (TextProof.bin suf) =
            .ok (TextProof.bin bs) := by
          simp only [Elixir.Ankole.Text.«truncate_utf8/3», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
            TextProof.byte_size_bin, Erlang.erlang.«=</2_integers», hle_int, Lynx.Except.bindReturned]
          rfl
        rw [htrunc]
        simp [Lynx.Except.bindReturned, «valid_truncated_result?/3», Lynx.Term.true, Lynx.Term.false,
          hvalid_bin, hv_bs, hle, hnot_gt]
      · have hgt : m < bs.length := by omega
        have hnot_le_int : ¬ ((bs.length : Int) ≤ (m : Int)) := by omega
        let avail := m - suf.length
        have havail_int : (if (0 : Int) ≤ (m : Int) - (suf.length : Int) then (m : Int) - (suf.length : Int) else 0) =
            (avail : Int) := by
          dsimp [avail]; split <;> omega
        let k := min bs.length avail
        have hk_int : (if (bs.length : Int) ≤ (avail : Int) then (bs.length : Int) else (avail : Int)) = (k : Int) := by
          dsimp [k]; split <;> omega
        have hpre : Elixir.Ankole.Text.«utf8_prefix/2» (TextProof.bin bs) (.integer avail) =
            .ok (TextProof.bin (TextProof.trimSuffixBytes (bs.take k))) := by
          simp only [Elixir.Ankole.Text.«utf8_prefix/2», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
            TextProof.byte_size_bin, TextProof.min_integers, hk_int, Lynx.Except.bindReturned]
          rw [TextProof.binary_part_zero bs k (by dsimp [k]; omega)]
          simp [htrim_suf]
        obtain ⟨hpre_val, hpre_le, _⟩ := TextProof.trimSuffixBytes_spec (bs.take k)
        generalize hpre_eq : TextProof.trimSuffixBytes (bs.take k) = pre at *
        have htk_le_avail : (bs.take k).length ≤ avail := by
          simp [List.length_take, k]
          exact Nat.min_le_right bs.length avail
        have hpre_le_avail : pre.length ≤ avail := by omega
        have hout_val : TextProof.validUtf8Term (TextProof.bin (pre ++ suf)) = Bool.true :=
          TextProof.validUtf8Term_append pre suf hpre_val hv_suf
        have hout_len : (pre.length : Int) + (suf.length : Int) ≤ (m : Int) := by
          dsimp [avail] at hpre_le_avail
          omega
        have htrunc : Elixir.Ankole.Text.«truncate_utf8/3» (TextProof.bin bs) (.integer m) (TextProof.bin suf) =
            .ok (TextProof.bin (pre ++ suf)) := by
          simp only [Elixir.Ankole.Text.«truncate_utf8/3», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok,
            Lynx.Term.true, Lynx.Term.false, TextProof.byte_size_bin,
            Erlang.erlang.«=</2_integers», hnot_le_int, Erlang.erlang.«-/2_integers»,
            TextProof.max_integers, havail_int, hpre, Except.bind, Lynx.Except.bindReturned,
            TextProof.binarySegment_bin, TextProof.append_bin]
        rw [htrunc]
        simp [Lynx.Except.bindReturned, «valid_truncated_result?/3», Lynx.Term.true, Lynx.Term.false,
          hvalid_bin, hout_val, hout_len, hgt]
      """
    )

    law(truncate_utf8_window_universal_contract(text, max_bytes, marker),
      requires:
        is_binary(text) and String.valid?(text) and is_binary(marker) and
          is_integer(max_bytes) and max_bytes >= 0,
      expects:
        valid_truncated_result?(
          text,
          max_bytes,
          Text.truncate_utf8_window(text, max_bytes, marker)
        ),
      proof: ~LEAN"""
      rw [«truncate_utf8_window_universal_contract:requires/3»] at requires
      rw [«truncate_utf8_window_universal_contract:ensures/3»]
      have hvalid_utf8 : ∀ t : Lynx.Term,
          Elixir.String.«valid_utf8?/1» t =
            .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) := by
        intro t
        suffices ∀ n (t : Lynx.Term), sizeOf t ≤ n →
            Elixir.String.«valid_utf8?/1» t =
              .ok (if TextProof.validUtf8Term t then Lynx.Term.true else Lynx.Term.false) by
          exact this (sizeOf t) t (Nat.le_refl _)
        intro n
        induction n with
        | zero => intro t hsz; cases t <;> simp at hsz
        | succ n ih =>
          intro t hsz
          rw [Elixir.String.«valid_utf8?/1».eq_def]
          cases hm : Lynx.Term.Bitstring.matchUtf8 t with
          | none =>
            rw [TextProof.validUtf8Term_of_none hm]
            cases he : Lynx.Term.Bitstring.matchEnd t <;> simp [hm, he, Lynx.Term.true, Lynx.Term.false]
          | some pair =>
            rcases pair with ⟨v, rest⟩
            rw [TextProof.validUtf8Term_of_some hm]
            have htail := TextProof.matchUtf8_rest_matchTail hm
            have hlt := Lynx.Term.Bitstring.matchUtf8_sizeOf hm
            simp only [hm, Lynx.Term.Bitstring.extract_some, htail, ↓reduceIte]
            exact ih rest (by omega)
      have hvalid_bin : ∀ xs : List UInt8,
          Elixir.String.«valid?/1» (TextProof.bin xs) =
            .ok (if TextProof.validUtf8Term (TextProof.bin xs) then Lynx.Term.true else Lynx.Term.false) := by
        intro xs
        simp [Elixir.String.«valid?/1», Elixir.String.«valid?/2», hvalid_utf8]
      have hbin_t : Erlang.erlang.«is_binary/1» text = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» text with
        | error e => simp [hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hb] at requires
              · simp [hb, hs, hf] at requires
          | _ => simp [hb] at requires
      obtain ⟨bs, rfl⟩ := TextProof.bin_of_is_binary hbin_t
      have hv_bs : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true := by
        by_cases hv : TextProof.validUtf8Term (TextProof.bin bs) = Bool.true
        · exact hv
        · simp [hvalid_bin, hv] at requires
      have hbin_m : Erlang.erlang.«is_binary/1» marker = .ok .true := by
        cases hb : Erlang.erlang.«is_binary/1» marker with
        | error e => simp [hvalid_bin, hv_bs, hb] at requires
        | ok v =>
          cases v with
          | atom s =>
            by_cases hs : s = "true"
            · subst hs; rfl
            · by_cases hf : s = "false"
              · subst hf; simp [hvalid_bin, hv_bs, hb] at requires
              · simp [hvalid_bin, hv_bs, hb, hs, hf] at requires
          | _ => simp [hvalid_bin, hv_bs, hb] at requires
      obtain ⟨mark, rfl⟩ := TextProof.bin_of_is_binary hbin_m
      have hm_nat : ∃ m : Nat, max_bytes = .integer m := by
        cases max_bytes with
        | integer z =>
          simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»] at requires
          exact ⟨z.toNat, by congr 1; omega⟩
        | _ => simp [hvalid_bin, hv_bs, Erlang.erlang.«is_integer/1»] at requires
      obtain ⟨m, rfl⟩ := hm_nat
      clear requires hbin_t hbin_m
      have htrim_suf : ∀ xs : List UInt8,
          Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
            .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) := by
        intro xs
        suffices ∀ n (xs : List UInt8), xs.length ≤ n →
            Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1» (TextProof.bin xs) =
              .ok (TextProof.bin (TextProof.trimSuffixBytes xs)) by
          exact this xs.length xs (Nat.le_refl _)
        intro n
        induction n with
        | zero =>
          intro xs hlen
          have hnil : xs = [] := List.eq_nil_of_length_eq_zero (by omega)
          subst hnil
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
          rfl
        | succ n ih =>
          intro xs hlen
          rcases xs with _ | ⟨b, rest⟩
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            rfl
          · rw [Elixir.Ankole.Text.«trim_invalid_utf8_suffix/1».eq_def, TextProof.trimSuffixBytes.eq_def]
            split
            · rename_i v heq
              exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
            · simp only [List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte, hvalid_bin]
              by_cases hv : TextProof.validUtf8Term (TextProof.bin (b :: rest)) = Bool.true
              · simp [hv, Lynx.Except.guard]
              · simp only [hv, Bool.false_eq_true, ↓reduceIte, TextProof.isMember_false_falsy, Lynx.Except.guard,
                  Lynx.Except.tryWith_ok, Lynx.Term.true, TextProof.byte_size_bin, List.length_cons,
                  Erlang.erlang.«-/2_integers», Lynx.Except.bindReturned]
                have hsub : (((rest.length + 1 : Nat) : Int) - 1) = (rest.length : Int) := by omega
                rw [hsub, Nat.add_sub_cancel]
                erw [TextProof.binary_part_zero (b :: rest) rest.length (by simp)]
                simp only [Lynx.Except.bindReturned]
                apply ih ((b :: rest).take rest.length)
                simp only [List.length_cons, List.length_take] at hlen ⊢
                omega
      have hprefix_any : ∀ (xs : List UInt8) (b : Nat),
          ∃ out : List UInt8,
            Elixir.Ankole.Text.«utf8_prefix/2» (TextProof.bin xs) (.integer b) =
              .ok (TextProof.bin out) ∧
            TextProof.validUtf8Term (TextProof.bin out) = Bool.true ∧
            out.length ≤ b := by
        intro xs b
        let k := min xs.length b
        have hk_int : (if (xs.length : Int) ≤ (b : Int) then (xs.length : Int) else (b : Int)) = (k : Int) := by
          dsimp [k]; split <;> omega
        refine ⟨TextProof.trimSuffixBytes (xs.take k), ?_, ?_, ?_⟩
        · simp only [Elixir.Ankole.Text.«utf8_prefix/2», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
            TextProof.byte_size_bin, TextProof.min_integers, hk_int, Lynx.Except.bindReturned]
          rw [TextProof.binary_part_zero xs k (by dsimp [k]; omega)]
          simp [htrim_suf]
        · exact (TextProof.trimSuffixBytes_spec (xs.take k)).1
        · have hle1 := (TextProof.trimSuffixBytes_spec (xs.take k)).2.1
          have hle2 : (xs.take k).length ≤ b := by
            simp [List.length_take, k]
            exact Nat.min_le_right xs.length b
          omega
      have htrim_pre : ∀ xs : List UInt8,
          Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1» (TextProof.bin xs) =
            .ok (TextProof.bin (TextProof.trimPrefixBytes xs)) := by
        intro xs
        induction xs with
        | nil =>
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1».eq_def]
          rfl
        | cons b rest ih =>
          rw [Elixir.Ankole.Text.«trim_invalid_utf8_prefix/1».eq_def]
          split
          · rename_i v heq
            exfalso; exact TextProof.bin_cons_ne_empty b rest v heq
          · simp only [TextProof.trimPrefixBytes, hvalid_bin]
            by_cases hv : TextProof.validUtf8Term (TextProof.bin (b :: rest)) = Bool.true
            · simp [hv, Lynx.Except.guard]
            · simp only [hv, Bool.false_eq_true, ↓reduceIte, TextProof.isMember_false_falsy, Lynx.Except.guard,
                Lynx.Except.tryWith_ok, Lynx.Term.true, TextProof.byte_size_bin, List.length_cons,
                Erlang.erlang.«-/2_integers», Lynx.Except.bindReturned]
              have hsub : (((rest.length + 1 : Nat) : Int) - 1) = (rest.length : Int) := by omega
              rw [hsub]
              erw [TextProof.binary_part_one (b :: rest) rest.length (by simp; omega)]
              simp [ih]
      have hsuffix_valid : ∀ (b : Nat),
          ∃ out : List UInt8,
            Elixir.Ankole.Text.«utf8_suffix/2» (TextProof.bin bs) (.integer b) =
              .ok (TextProof.bin out) ∧
            TextProof.validUtf8Term (TextProof.bin out) = Bool.true ∧
            out.length ≤ b := by
        intro b
        by_cases hle : bs.length ≤ b
        · have hle_int : (bs.length : Int) ≤ (b : Int) := by omega
          refine ⟨bs, ?_, hv_bs, hle⟩
          simp [Elixir.Ankole.Text.«utf8_suffix/2», hle_int, Lynx.Except.guard, Lynx.Term.true]
        · have hgt : b < bs.length := by omega
          have hnot_le_int : ¬ ((bs.length : Int) ≤ (b : Int)) := by omega
          rcases b with _ | k
          · have hbs_ne : bs ≠ [] := by intro h; subst h; simp at hgt
            refine ⟨[], ?_, TextProof.validUtf8Term_nil, Nat.zero_le _⟩
            simp [Elixir.Ankole.Text.«utf8_suffix/2», hnot_le_int, hbs_ne, Lynx.Except.guard,
              Lynx.Term.true, Lynx.Term.false]
          · have hk_pos : (0 : Int) < ((k + 1 : Nat) : Int) := by omega
            have hsub_int : (bs.length : Int) - ((k + 1 : Nat) : Int) = ((bs.length - (k + 1) : Nat) : Int) := by omega
            have hslice_take : ((bs.drop (bs.length - (k + 1))).take (k + 1)) = bs.drop (bs.length - (k + 1)) := by
              rw [List.take_of_length_le (by simp; omega)]
            obtain ⟨hout_val, hout_le, _⟩ := TextProof.trimPrefixBytes_spec (bs.drop (bs.length - (k + 1)))
            generalize hout_eq : TextProof.trimPrefixBytes (bs.drop (bs.length - (k + 1))) = out at *
            have hsl_len : (bs.drop (bs.length - (k + 1))).length = k + 1 := by simp; omega
            refine ⟨out, ?_, hout_val, by omega⟩
            unfold Elixir.Ankole.Text.«utf8_suffix/2»
            simp only [TextProof.byte_size_bin, Erlang.erlang.«=</2_integers», hnot_le_int,
              ↓reduceIte, pure, Except.pure, Lynx.Except.bindReturned, Lynx.Except.tryWith_ok,
              Lynx.Except.guard, Lynx.Term.true, Lynx.Term.false]
            split
            · simp_all
            · simp only [Lynx.Except.andAlso_eq, TextProof.is_binary_bin, TextProof.gt_integers,
                hk_pos, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
                TextProof.byte_size_bin, Erlang.erlang.«-/2_integers», hsub_int,
                Lynx.Except.bindReturned]
              rw [TextProof.binary_part_bin bs (bs.length - (k + 1)) (k + 1) (by omega)]
              simp [hslice_take, htrim_pre, hout_eq]
      by_cases hle : bs.length ≤ m
      · have hle_int : (bs.length : Int) ≤ (m : Int) := by omega
        have hnot_gt : ¬ (m < bs.length) := by omega
        have hwin : Elixir.Ankole.Text.«truncate_utf8_window/3» (TextProof.bin bs) (.integer m) (TextProof.bin mark) =
            .ok (TextProof.bin bs) := by
          simp only [Elixir.Ankole.Text.«truncate_utf8_window/3», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok, Lynx.Term.true,
            TextProof.byte_size_bin, Erlang.erlang.«=</2_integers», hle_int, Lynx.Except.bindReturned]
          rfl
        rw [hwin]
        simp [Lynx.Except.bindReturned, «valid_truncated_result?/3», Lynx.Term.true, Lynx.Term.false,
          hvalid_bin, hv_bs, hle, hnot_gt]
      · have hgt : m < bs.length := by omega
        have hnot_le_int : ¬ ((bs.length : Int) ≤ (m : Int)) := by omega
        obtain ⟨mark2, hmark2_eq, hmark2_val, hmark2_le⟩ := hprefix_any mark m
        let avail := m - mark2.length
        have havail_int : (m : Int) - (mark2.length : Int) = (avail : Int) := by dsimp [avail]; omega
        have havail1_int : (avail : Int) + 1 = ((avail + 1 : Nat) : Int) := by omega
        let head_b := (avail + 1) / 2
        let tail_b := avail - head_b
        have htail_int : (avail : Int) - (head_b : Int) = (tail_b : Int) := by
          dsimp [head_b, tail_b]; omega
        obtain ⟨hd, hhd_eq, hhd_val, hhd_le⟩ := hprefix_any bs head_b
        obtain ⟨tl, htl_eq, htl_val, htl_le⟩ := hsuffix_valid tail_b
        have hout_val : TextProof.validUtf8Term (TextProof.bin (hd ++ (mark2 ++ tl))) = Bool.true :=
          TextProof.validUtf8Term_append hd (mark2 ++ tl) hhd_val
            (TextProof.validUtf8Term_append mark2 tl hmark2_val htl_val)
        have hout_len : (hd.length : Int) + ((mark2.length : Int) + (tl.length : Int)) ≤ (m : Int) := by
          dsimp [avail, head_b, tail_b] at *
          omega
        dsimp only [head_b, tail_b] at hhd_eq htl_eq htail_int
        have hwin : Elixir.Ankole.Text.«truncate_utf8_window/3» (TextProof.bin bs) (.integer m) (TextProof.bin mark) =
            .ok (TextProof.bin (hd ++ (mark2 ++ tl))) := by
          simp only [Elixir.Ankole.Text.«truncate_utf8_window/3», Lynx.Except.andAlso_eq,
            TextProof.is_binary_bin, Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers»,
            Int.ofNat_nonneg, ↓reduceIte, Lynx.Except.guard, Lynx.Except.tryWith_ok,
            Lynx.Term.true, Lynx.Term.false, TextProof.byte_size_bin,
            Erlang.erlang.«=</2_integers», hnot_le_int, hmark2_eq,
            Erlang.erlang.«-/2_integers», havail_int, Erlang.erlang.«+/2_integers», havail1_int,
            TextProof.div2_nat, htail_int, hhd_eq, htl_eq,
            Except.bind, Lynx.Except.bindReturned, TextProof.binarySegment_bin, TextProof.append_bin]
        rw [hwin]
        simp [Lynx.Except.bindReturned, «valid_truncated_result?/3», Lynx.Term.true, Lynx.Term.false,
          hvalid_bin, hout_val, hout_len, hgt]
      """
    )
  end

  test "multibyte UTF-8 prefixes, suffixes, and windows preserve scalar boundaries" do
    cjk = "你好世界"
    emoji = "🚀🔥✨🎉"

    for budget <- 0..16 do
      pre_cjk = Text.utf8_prefix(cjk, budget)
      assert valid_prefix_result?(cjk, budget, pre_cjk)

      suf_cjk = Text.utf8_suffix(cjk, budget)
      assert valid_suffix_result?(cjk, budget, suf_cjk)

      win_emoji = Text.truncate_utf8_window(emoji, budget, "...[truncated]...")
      assert valid_truncated_result?(emoji, budget, win_emoji)
    end

    assert valid_prefix_result?(
             <<0xFF, 0xE4, 0xBD, 0xA0>>,
             4,
             Text.utf8_prefix(<<0xFF, 0xE4, 0xBD, 0xA0>>, 4)
           )

    assert Text.truncate_utf8(cjk, 10, "...") |> byte_size() <= 10
  end
end
