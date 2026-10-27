defmodule Ankole.Formal.Pod.PositionLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Pod.Position

  defp spec_digit?(c), do: c in ?0..?9 or c in ?A..?Z or c in ?a..?z

  defp spec_bound?(nil), do: true
  defp spec_bound?(key) when is_binary(key), do: true
  defp spec_bound?(_), do: false

  defp spec_valid_key?(key) when is_binary(key), do: spec_valid_bytes?(key)
  defp spec_valid_key?(_), do: false

  defp spec_valid_bytes?(<<?0>>), do: false
  defp spec_valid_bytes?(<<c>>), do: spec_digit?(c)
  defp spec_valid_bytes?(<<c, rest::binary>>), do: spec_digit?(c) and spec_valid_bytes?(rest)
  defp spec_valid_bytes?(_), do: false

  defp spec_valid_or_empty?(""), do: true
  defp spec_valid_or_empty?(key), do: spec_valid_key?(key)

  defp valid_between_result?({:ok, mid}, lower, upper) do
    spec_valid_key?(mid) and lower < mid and mid < upper
  end

  defp valid_between_result?(_, _lower, _upper), do: false

  defp valid_after_result?({:ok, key}, lower) do
    spec_valid_key?(key) and lower < key
  end

  defp valid_after_result?(_, _lower), do: false

  defp valid_before_result?({:ok, key}, upper) do
    spec_valid_key?(key) and key < upper
  end

  defp valid_before_result?(_, _upper), do: false

  defp expected_between?(lower, upper, result) do
    cond do
      is_nil(lower) and is_nil(upper) ->
        result == {:ok, "V"}

      is_nil(lower) and spec_valid_key?(upper) ->
        valid_before_result?(result, upper)

      spec_valid_or_empty?(lower) and is_nil(upper) ->
        valid_after_result?(result, lower)

      spec_valid_or_empty?(lower) and spec_valid_key?(upper) and lower < upper ->
        valid_between_result?(result, lower, upper)

      true ->
        result == :error
    end
  end

  laws "Position.between universal contracts" do
    prelude(~LEAN"""
    module

    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    public import Lynx.Term.Bitstring.Matching
    import all Lynx.Term.Compare

    @[expose] public section

    namespace PositionProof
    open Lynx

    abbrev bin (bs : List UInt8) : Term :=
      .bitstring ⟨bs.toArray⟩ 0 (Term.Bitstring.valid_aligned _)

    def isDigit (b : UInt8) : Bool :=
      (48 ≤ b.toNat && b.toNat ≤ 57) ||
      (65 ≤ b.toNat && b.toNat ≤ 90) ||
      (97 ≤ b.toNat && b.toNat ≤ 122)

    def ValidNonempty : List UInt8 → Bool
      | [] => false
      | [b] => isDigit b && b != 48
      | b :: rest => isDigit b && ValidNonempty rest

    def ValidOrEmpty : List UInt8 → Bool
      | [] => true
      | bs => ValidNonempty bs

    def digitIdx (b : UInt8) : Nat :=
      if b.toNat ≤ 57 then b.toNat - 48
      else if b.toNat ≤ 90 then b.toNat - 65 + 10
      else b.toNat - 97 + 36

    def digitByte (i : Nat) : UInt8 :=
      if i < 10 then UInt8.ofNat (48 + i)
      else if i < 36 then UInt8.ofNat (65 + i - 10)
      else UInt8.ofNat (97 + i - 36)

    def raiseLastBytes : List UInt8 → Option (List UInt8)
      | [] => none
      | b :: rest =>
        if b == 122 then
          (raiseLastBytes rest).map (122 :: ·)
        else
          match raiseLastBytes rest with
          | some raised => some (b :: raised)
          | none => some [digitByte (digitIdx b + 1)]

    def afterKeyBytes (bs : List UInt8) : List UInt8 :=
      match bs with
      | [] => [86]
      | _ =>
        match raiseLastBytes bs with
        | some raised => raised
        | none => bs ++ [86]

    def stepBytes (lower : List UInt8) (u : UInt8) (uRest : List UInt8) : List UInt8 :=
      let (low, lRest) :=
        match lower with
        | [] => (0, [])
        | l :: rest => (digitIdx l, rest)
      let high := digitIdx u
      if high - low > 1 then
        [digitByte ((low + high + 1) / 2)]
      else if !uRest.isEmpty then
        [u]
      else
        digitByte low :: afterKeyBytes lRest

    def midpointBytes : List UInt8 → List UInt8 → List UInt8
      | c :: lRest, u :: uRest =>
        if u == c then c :: midpointBytes lRest uRest
        else stepBytes (c :: lRest) u uRest
      | [], u :: uRest =>
        if u == 48 then 48 :: midpointBytes [] uRest
        else stepBytes [] u uRest
      | _, [] => []

    /-! ### Binary lexicographic comparison in Lynx -/

    private def natBits : Nat → Nat → List Bool
      | 0, _ => []
      | k + 1, n => decide (2 ^ k ≤ n) :: natBits k (n % 2 ^ k)

    private theorem nat_compare_iff (a b : Nat) :
        Ord.compare a b = if a < b then .lt else if a = b then .eq else .gt := rfl

    private theorem compare_natBits (k : Nat) :
        ∀ x y : Nat, x < 2 ^ k → y < 2 ^ k →
          List.compareLex Ord.compare (natBits k x) (natBits k y) = Ord.compare x y := by
      induction k with
      | zero =>
        intro x y hx hy
        have : x = 0 := by omega
        have : y = 0 := by omega
        subst x y; rfl
      | succ k ih =>
        intro x y hx hy
        have hpos : 0 < 2 ^ k := Nat.one_le_pow k 2 (by decide)
        have hpow : 2 ^ (k + 1) = 2 * 2 ^ k := by rw [Nat.pow_succ]; omega
        simp only [natBits, List.compareLex_cons_cons]
        have hxm : x % 2 ^ k < 2 ^ k := Nat.mod_lt _ hpos
        have hym : y % 2 ^ k < 2 ^ k := Nat.mod_lt _ hpos
        rw [ih _ _ hxm hym]
        by_cases bx : 2 ^ k ≤ x <;> by_cases by_ : 2 ^ k ≤ y
        · have ex : x % 2 ^ k = x - 2 ^ k :=
            (Nat.mod_eq_sub_mod bx).trans (Nat.mod_eq_of_lt (by omega))
          have ey : y % 2 ^ k = y - 2 ^ k :=
            (Nat.mod_eq_sub_mod by_).trans (Nat.mod_eq_of_lt (by omega))
          simp only [bx, by_, decide_true, ex, ey]
          change Ordering.eq.then (Ord.compare (x - 2 ^ k) (y - 2 ^ k)) = Ord.compare x y
          rw [Ordering.eq_then, nat_compare_iff, nat_compare_iff]
          by_cases h1 : x < y <;> by_cases h2 : x = y
          · omega
          · have hsub : x - 2 ^ k < y - 2 ^ k := by omega
            simp [h1, hsub]
          · simp [h2]
          · have hsub1 : ¬ (x - 2 ^ k < y - 2 ^ k) := by omega
            have hsub2 : ¬ (x - 2 ^ k = y - 2 ^ k) := by omega
            simp [h1, h2, hsub1, hsub2]
        · simp only [bx, by_, decide_true, decide_false]
          change Ordering.gt.then _ = Ord.compare x y
          rw [Ordering.gt_then, nat_compare_iff]
          have h1 : ¬ (x < y) := by omega
          have h2 : ¬ (x = y) := by omega
          simp [h1, h2]
        · simp only [bx, by_, decide_false, decide_true]
          change Ordering.lt.then _ = Ord.compare x y
          rw [Ordering.lt_then, nat_compare_iff]
          have h1 : x < y := by omega
          simp [h1]
        · have ex : x % 2 ^ k = x := Nat.mod_eq_of_lt (by omega)
          have ey : y % 2 ^ k = y := Nat.mod_eq_of_lt (by omega)
          simp only [bx, by_, decide_false, ex, ey]
          change Ordering.eq.then (Ord.compare x y) = Ord.compare x y
          rw [Ordering.eq_then]

    private theorem byte_bits_eq_natBits_fin : ∀ n : Fin 256,
        ((List.range 8).map fun i => (UInt8.ofNat n.val).toBitVec.getMsbD i) = natBits 8 n.val := by
      decide +kernel

    private theorem compare_byte_bits (x y : UInt8) :
        List.compareLex Ord.compare
          ((List.range 8).map fun i => x.toBitVec.getMsbD i)
          ((List.range 8).map fun i => y.toBitVec.getMsbD i) =
          Ord.compare x y := by
      have hx := byte_bits_eq_natBits_fin ⟨x.toNat, x.toNat_lt⟩
      have hy := byte_bits_eq_natBits_fin ⟨y.toNat, y.toNat_lt⟩
      rw [UInt8.ofNat_toNat] at hx hy
      rw [hx, hy, compare_natBits 8 x.toNat y.toNat x.toNat_lt y.toNat_lt]
      simp only [Ord.compare, compareOfLessAndEq, UInt8.lt_iff_toNat_lt, UInt8.toNat_inj]

    private theorem compareLex_append_fixed {α : Type} (cmp : α → α → Ordering)
        (x y : List α) (xs ys : List α) (hlen : x.length = y.length) :
        List.compareLex cmp (x ++ xs) (y ++ ys) =
          (List.compareLex cmp x y).then (List.compareLex cmp xs ys) := by
      induction x generalizing y with
      | nil =>
        cases y with
        | nil => simp [List.compareLex_nil_nil]
        | cons _ _ => simp at hlen
      | cons a as ih =>
        cases y with
        | nil => simp at hlen
        | cons b bs =>
          simp only [List.length_cons, Nat.add_right_cancel_iff] at hlen
          simp only [List.cons_append, List.compareLex_cons_cons]
          cases cmp a b <;> simp [ih bs hlen]

    private theorem size_list (bs : List UInt8) : (ByteArray.mk bs.toArray).size = bs.length := by
      simp [ByteArray.size]

    private theorem toBits_empty : Term.Bitstring.toBits ⟨([] : List UInt8).toArray⟩ 0 = [] :=
      List.eq_nil_of_length_eq_zero (by rw [Term.Bitstring.toBits_length_aligned]; rfl)

    private theorem toBits_cons_take (b : UInt8) (bs : List UInt8) :
        (Term.Bitstring.toBits ⟨(b :: bs).toArray⟩ 0).take 8 =
          (List.range 8).map fun i => b.toBitVec.getMsbD i := by
      apply List.ext_getElem
      · simp [Term.Bitstring.toBits_length_aligned, size_list]; omega
      · intro i h₁ h₂
        simp at h₂
        have hi : i / 8 = 0 := by omega
        have hm : i % 8 = i := by omega
        simp only [List.getElem_take, Term.Bitstring.toBits, List.getElem_map, List.getElem_range, hi, hm]
        have hj : 0 < (ByteArray.mk (b :: bs).toArray).size := by simp [size_list]
        simp [getElem!_pos (ByteArray.mk (b :: bs).toArray) 0 hj, ByteArray.getElem_eq_getElem_data]

    private theorem toBits_cons_drop (b : UInt8) (bs : List UInt8) :
        (Term.Bitstring.toBits ⟨(b :: bs).toArray⟩ 0).drop 8 =
          Term.Bitstring.toBits ⟨bs.toArray⟩ 0 := by
      apply List.ext_getElem
      · simp [Term.Bitstring.toBits_length_aligned, size_list]; omega
      · intro i h₁ h₂
        have hl := Term.Bitstring.toBits_length_aligned (ByteArray.mk bs.toArray)
        simp only [size_list] at hl
        have hq : (8 + i) / 8 = i / 8 + 1 := by omega
        have hr : (8 + i) % 8 = i % 8 := by omega
        simp only [List.getElem_drop, Term.Bitstring.toBits, List.getElem_map, List.getElem_range, hq, hr]
        have h1 : i / 8 + 1 < (ByteArray.mk (b :: bs).toArray).size := by simp [size_list]; omega
        have h2 : i / 8 < (ByteArray.mk bs.toArray).size := by simp [size_list]; omega
        simp [getElem!_pos (ByteArray.mk (b :: bs).toArray) (i / 8 + 1) h1,
          getElem!_pos (ByteArray.mk bs.toArray) (i / 8) h2, ByteArray.getElem_eq_getElem_data]

    private theorem toBits_cons_local (b : UInt8) (bs : List UInt8) :
        Term.Bitstring.toBits ⟨(b :: bs).toArray⟩ 0 =
          ((List.range 8).map fun i => b.toBitVec.getMsbD i) ++
            Term.Bitstring.toBits ⟨bs.toArray⟩ 0 := by
      conv => lhs; rw [← List.take_append_drop 8 (Term.Bitstring.toBits _ 0)]
      rw [toBits_cons_take, toBits_cons_drop]

    theorem compare_bin (a b : List UInt8) :
        Term.compare (bin a) (bin b) = List.compareLex Ord.compare a b := by
      rw [Term.compare_eq_step]
      simp only [Term.Compare.compareStep]
      induction a generalizing b with
      | nil =>
        cases b with
        | nil => rw [toBits_empty]; rfl
        | cons y ys => rw [toBits_empty, toBits_cons_local]; rfl
      | cons x xs ih =>
        cases b with
        | nil => rw [toBits_cons_local, toBits_empty]; rfl
        | cons y ys =>
          rw [toBits_cons_local, toBits_cons_local,
            compareLex_append_fixed _ _ _ _ _ (by simp),
            compare_byte_bits, List.compareLex_cons_cons, ih ys]

    @[simp] theorem compare_eq_atom (a : Term) (name : String) :
        (Term.compare a (.atom name) = .eq) ↔ a = .atom name := by
      cases a <;> rw [Term.compare_eq_step] <;> simp [Term.Compare.compareStep]

    @[simp] theorem atom_compare_eq (name : String) (a : Term) :
        (Term.compare (.atom name) a = .eq) ↔ a = .atom name := by
      rw [Std.OrientedCmp.eq_swap (cmp := Term.compare), Ordering.swap_eq_eq]
      exact compare_eq_atom a name

    @[simp] theorem isMember_nil_false_nil :
        Term.isMember (.atom "nil") [.atom "false", .atom "nil"] = .atom "true" := by
      simp [Term.isMember, Term.exactCompare_eq_step, Term.Compare.compareStep]

    @[simp] theorem isMember_true_false_nil :
        Term.isMember (.atom "true") [.atom "false", .atom "nil"] = .atom "false" := by
      simp [Term.isMember, Term.exactCompare_eq_step, Term.Compare.compareStep]

    theorem int_ne_of_uint8_ne {b : UInt8} {k : UInt8} (h : b ≠ k) :
        Term.integer b.toNat ≠ Term.integer k.toNat := by
      intro heq
      injection heq with heq
      apply h
      exact UInt8.toNat_inj.mp (Int.ofNat.inj heq)

    @[simp] theorem gt_integers (x y : Int) :
        Erlang.erlang.«>/2» (.integer x) (.integer y) =
          .ok (if y < x then Term.true else Term.false) := by
      simp [Erlang.erlang.«>/2», Ordering.isGT_iff_eq_gt, Int.compare_eq_gt]

    @[simp] theorem div_nat_two (n : Nat) :
        Erlang.erlang.«div/2» (.integer n) (.integer 2) = .ok (.integer ((n / 2 : Nat) : Int)) := by
      simp [Erlang.erlang.«div/2», Int.tdiv]

    @[simp] theorem byte_size_bin (bs : List UInt8) :
        Erlang.erlang.«byte_size/1» (bin bs) = .ok (.integer bs.length) := by
      simp [Erlang.erlang.«byte_size/1», size_list]

    @[simp] theorem matchEnd_nil : Term.Bitstring.matchEnd (bin []) = true := rfl

    @[simp] theorem matchEnd_cons (b : UInt8) (bs : List UInt8) :
        Term.Bitstring.matchEnd (bin (b :: bs)) = false := by
      have hsz : (ByteArray.mk (b :: bs).toArray).size = bs.length + 1 := by
        simp [ByteArray.size]
      simp [Term.Bitstring.matchEnd, Term.Bitstring.bitSize, hsz]

    @[simp] theorem matchInteger_nil :
        Term.Bitstring.matchInteger (bin []) (.integer 8) 1 false false = none := by
      have hsz : (ByteArray.mk ([] : List UInt8).toArray).size = 0 := rfl
      simp [Term.Bitstring.matchInteger, toBits_empty]

    @[simp] theorem matchInteger_cons (b : UInt8) (bs : List UInt8) :
        Term.Bitstring.matchInteger (bin (b :: bs)) (.integer 8) 1 false false =
          some (.integer b.toNat, bin bs) :=
      Term.Bitstring.matchInteger_byte b bs (Term.Bitstring.valid_aligned _)

    @[simp] theorem matchTail_bin (bs : List UInt8) :
        Term.Bitstring.matchTail (bin bs) (.atom "all") 8 = true := by
      cases bs with
      | nil => rfl
      | cons b rest =>
        have hsz : (ByteArray.mk (b :: rest).toArray).size = rest.length + 1 := by
          simp [ByteArray.size]
        simp [Term.Bitstring.matchTail, Term.Bitstring.bitSize, hsz]

    @[simp] theorem integerSegment_bin (b : UInt8) :
        Term.Bitstring.integerSegment (.integer b.toNat) (.integer 8) 1 false = .ok (bin [b]) :=
      Term.Bitstring.integerSegment_byte b

    @[simp] theorem binarySegment_bin (bs : List UInt8) :
        Term.Bitstring.binarySegment (bin bs) (.atom "all") 8 = .ok (bin bs) :=
      Term.Bitstring.binarySegment_aligned _

    @[simp] theorem append_bin (xs ys : List UInt8) :
        Term.Bitstring.append (bin xs) (bin ys) = .ok (bin (xs ++ ys)) :=
      Term.Bitstring.append_bytes xs ys

    /-! ### Digit arithmetic & order properties -/

    theorem digit_props_fin : ∀ n : Fin 256,
        isDigit (UInt8.ofNat n.val) = true →
          digitIdx (UInt8.ofNat n.val) < 62 ∧
          digitByte (digitIdx (UInt8.ofNat n.val)) = UInt8.ofNat n.val ∧
          (UInt8.ofNat n.val == 48) = decide (digitIdx (UInt8.ofNat n.val) = 0) ∧
          (UInt8.ofNat n.val == 122) = decide (digitIdx (UInt8.ofNat n.val) = 61) := by
      decide +kernel

    theorem digit_props (b : UInt8) (hb : isDigit b = true) :
        digitIdx b < 62 ∧
        digitByte (digitIdx b) = b ∧
        (b == 48) = decide (digitIdx b = 0) ∧
        (b == 122) = decide (digitIdx b = 61) := by
      have h := digit_props_fin ⟨b.toNat, b.toNat_lt⟩ (by rwa [UInt8.ofNat_toNat])
      rwa [UInt8.ofNat_toNat] at h

    theorem digitByte_props_fin : ∀ i : Fin 62,
        isDigit (digitByte i.val) = true ∧
        digitIdx (digitByte i.val) = i.val ∧
        (digitByte i.val == 48) = decide (i.val = 0) := by
      decide +kernel

    theorem digitByte_props (i : Nat) (hi : i < 62) :
        isDigit (digitByte i) = true ∧
        digitIdx (digitByte i) = i ∧
        (digitByte i == 48) = decide (i = 0) :=
      digitByte_props_fin ⟨i, hi⟩

    theorem digitByte_lt_iff (i j : Nat) (hi : i < 62) (hj : j < 62) :
        Ord.compare (digitByte i) (digitByte j) = Ord.compare i j := by
      have h : ∀ a b : Fin 62,
          Ord.compare (digitByte a.val) (digitByte b.val) = Ord.compare a.val b.val := by
        decide +kernel
      exact h ⟨i, hi⟩ ⟨j, hj⟩

    theorem digit_compare_idx (a b : UInt8) (ha : isDigit a = true) (hb : isDigit b = true) :
        Ord.compare a b = Ord.compare (digitIdx a) (digitIdx b) := by
      have pa := digit_props a ha
      have pb := digit_props b hb
      conv => lhs; rw [← pa.2.1, ← pb.2.1]
      exact digitByte_lt_iff _ _ pa.1 pb.1

    /-! ### Key validity & lexicographic order properties -/

    theorem validNonempty_ne_nil {bs : List UInt8} (h : ValidNonempty bs = true) : bs ≠ [] := by
      rintro rfl; cases h

    theorem validNonempty_cons_of_nonempty (b : UInt8) (bs : List UInt8)
        (hb : isDigit b = true) (hbs : ValidNonempty bs = true) :
        ValidNonempty (b :: bs) = true := by
      cases bs with
      | nil => simp [ValidNonempty] at hbs
      | cons c cs => simp [ValidNonempty, hb, hbs]

    theorem validOrEmpty_cons_inv {b : UInt8} {bs : List UInt8} (h : ValidOrEmpty (b :: bs) = true) :
        isDigit b = true ∧ ValidOrEmpty bs = true := by
      cases bs with
      | nil => simp [ValidOrEmpty, ValidNonempty] at h; exact ⟨h.1, rfl⟩
      | cons c cs =>
        simp [ValidOrEmpty, ValidNonempty] at h
        exact ⟨h.1, h.2⟩

    theorem validNonempty_append {xs ys : List UInt8}
        (hxs : ∀ b ∈ xs, isDigit b = true) (hys : ValidNonempty ys = true) :
        ValidNonempty (xs ++ ys) = true := by
      induction xs with
      | nil => exact hys
      | cons b bs ih =>
        simp only [List.cons_append]
        exact validNonempty_cons_of_nonempty b (bs ++ ys)
          (hxs b (List.mem_cons_self ..))
          (ih (fun x hx => hxs x (List.mem_cons_of_mem _ hx)))

    theorem compareLex_prefix_lt (xs : List UInt8) (y : UInt8) (ys : List UInt8) :
        List.compareLex Ord.compare xs (xs ++ y :: ys) = .lt := by
      induction xs with
      | nil => rfl
      | cons x xs ih =>
        simp [List.cons_append, List.compareLex_cons_cons, Std.ReflCmp.compare_self, ih]

    theorem raiseLastBytes_spec (bs : List UInt8) (h : ValidOrEmpty bs = true) :
        match raiseLastBytes bs with
        | some raised =>
          ValidNonempty raised = true ∧ List.compareLex Ord.compare bs raised = .lt
        | none =>
          ∀ b ∈ bs, b = 122 := by
      induction bs with
      | nil => simp [raiseLastBytes]
      | cons b rest ih =>
        obtain ⟨hb, hrest⟩ := validOrEmpty_cons_inv h
        have ih' := ih hrest
        simp only [raiseLastBytes]
        by_cases htop : b == 122
        · simp only [htop, ↓reduceIte]
          have hb122 : b = 122 := eq_of_beq htop
          cases hrl : raiseLastBytes rest with
          | none =>
            rw [hrl] at ih'
            simp only [Option.map_none]
            intro x hx
            rcases List.mem_cons.mp hx with rfl | hx
            · exact hb122
            · exact ih' x hx
          | some raised =>
            rw [hrl] at ih'
            simp only [Option.map_some]
            refine ⟨validNonempty_cons_of_nonempty 122 raised (by decide) ih'.1, ?_⟩
            subst hb122
            simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, ih'.2]
        · simp only [htop, Bool.false_eq_true, ↓reduceIte]
          cases hrl : raiseLastBytes rest with
          | some raised =>
            rw [hrl] at ih'
            refine ⟨validNonempty_cons_of_nonempty b raised hb ih'.1, ?_⟩
            simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, ih'.2]
          | none =>
            have pb := digit_props b hb
            have hne61 : digitIdx b ≠ 61 := by
              intro heq
              have : (b == 122) = true := by rw [pb.2.2.2]; simp [heq]
              exact htop this
            have hlt61 : digitIdx b < 61 := by have := pb.1; omega
            have pnext := digitByte_props (digitIdx b + 1) (by omega)
            have hnz : (digitByte (digitIdx b + 1) != 48) = true := by
              simp [bne, pnext.2.2]
            refine ⟨by simp [ValidNonempty, pnext.1, hnz], ?_⟩
            simp only [List.compareLex_cons_cons]
            have hcmp : Ord.compare b (digitByte (digitIdx b + 1)) = .lt := by
              rw [digit_compare_idx b _ hb pnext.1, pnext.2.1, nat_compare_iff]
              simp
            rw [hcmp]; rfl

    theorem afterKeyBytes_spec (bs : List UInt8) (h : ValidOrEmpty bs = true) :
        ValidNonempty (afterKeyBytes bs) = true ∧
        List.compareLex Ord.compare bs (afterKeyBytes bs) = .lt := by
      cases bs with
      | nil =>
        refine ⟨by decide, rfl⟩
      | cons b rest =>
        have spec := raiseLastBytes_spec (b :: rest) h
        simp only [afterKeyBytes]
        cases hrl : raiseLastBytes (b :: rest) with
        | some raised =>
          rw [hrl] at spec; exact spec
        | none =>
          rw [hrl] at spec
          refine ⟨validNonempty_append (fun x hx => by rw [spec x hx]; decide) (by decide),
            compareLex_prefix_lt (b :: rest) 86 []⟩

    theorem stepBytes_spec (lower : List UInt8) (u : UInt8) (uRest : List UInt8)
        (hl : ValidOrEmpty lower = true)
        (hu : ValidNonempty (u :: uRest) = true)
        (hlu : List.compareLex Ord.compare lower (u :: uRest) = .lt)
        (hne_head : ∀ c lRest, lower = c :: lRest → u ≠ c)
        (hne_zero : lower = [] → u ≠ 48) :
        let mid := stepBytes lower u uRest
        ValidNonempty mid = true ∧
        List.compareLex Ord.compare lower mid = .lt ∧
        List.compareLex Ord.compare mid (u :: uRest) = .lt := by
      have hu_or := validOrEmpty_cons_inv (show ValidOrEmpty (u :: uRest) = true from hu)
      have hu_digit : isDigit u = true := hu_or.1
      have pu := digit_props u hu_digit
      cases lower with
      | nil =>
        have hu48 : u ≠ 48 := hne_zero rfl
        have hhigh_pos : 1 ≤ digitIdx u := by
          have h0 : (u == 48) = false := beq_false_of_ne hu48
          rw [pu.2.2.1] at h0
          have : digitIdx u ≠ 0 := of_decide_eq_false h0
          omega
        simp only [stepBytes, Nat.sub_zero]
        by_cases hgap : digitIdx u > 1
        · simp only [hgap, ↓reduceIte, Nat.zero_add]
          have hm_lo : 1 ≤ (digitIdx u + 1) / 2 := by omega
          have hm_hi : (digitIdx u + 1) / 2 < digitIdx u := by have := pu.1; omega
          have hm_62 : (digitIdx u + 1) / 2 < 62 := by have := pu.1; omega
          have pm := digitByte_props ((digitIdx u + 1) / 2) hm_62
          have hnz : (digitByte ((digitIdx u + 1) / 2) != 48) = true := by
            have : (digitIdx u + 1) / 2 ≠ 0 := by omega
            simp [bne, pm.2.2, this]
          refine ⟨by rw [ValidNonempty, pm.1, hnz]; rfl, rfl, ?_⟩
          simp only [List.compareLex_cons_cons]
          have hcmp : Ord.compare (digitByte ((digitIdx u + 1) / 2)) u = .lt := by
            rw [digit_compare_idx _ _ pm.1 hu_digit, pm.2.1, nat_compare_iff]
            simp [hm_hi]
          rw [hcmp]; rfl
        · simp only [hgap, ↓reduceIte]
          have hhigh1 : digitIdx u = 1 := by omega
          cases uRest with
          | nil =>
            simp only [List.isEmpty_nil, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
            have p0 := digitByte_props 0 (by decide)
            have ha := afterKeyBytes_spec [] rfl
            refine ⟨validNonempty_cons_of_nonempty (digitByte 0) (afterKeyBytes []) p0.1 ha.1,
              rfl, ?_⟩
            simp only [List.compareLex_cons_cons]
            have hcmp : Ord.compare (digitByte 0) u = .lt := by
              rw [digit_compare_idx _ _ p0.1 hu_digit, p0.2.1, hhigh1]; rfl
            rw [hcmp]; rfl
          | cons ur urs =>
            simp only [List.isEmpty_cons, Bool.not_false, ↓reduceIte]
            have hnz : (u != 48) = true := by simp [bne, hu48]
            refine ⟨by rw [ValidNonempty, hu_digit, hnz]; rfl, rfl, ?_⟩
            rw [List.compareLex_cons_cons, Std.ReflCmp.compare_self (cmp := Ord.compare) (a := u)]; rfl
      | cons l lRest =>
        obtain ⟨hl_digit, hlRest⟩ := validOrEmpty_cons_inv hl
        have pl := digit_props l hl_digit
        have hul_ne : u ≠ l := hne_head l lRest rfl
        have hlow_lt_high : digitIdx l < digitIdx u := by
          simp only [List.compareLex_cons_cons] at hlu
          rw [digit_compare_idx l u hl_digit hu_digit, nat_compare_iff] at hlu
          by_cases hlt : digitIdx l < digitIdx u
          · exact hlt
          · by_cases heq : digitIdx l = digitIdx u
            · exfalso; apply hul_ne
              rw [← pu.2.1, ← pl.2.1, heq]
            · simp [hlt, heq] at hlu
        simp only [stepBytes]
        by_cases hgap : digitIdx u - digitIdx l > 1
        · simp only [hgap, ↓reduceIte]
          have hm_lo : digitIdx l < (digitIdx l + digitIdx u + 1) / 2 := by omega
          have hm_hi : (digitIdx l + digitIdx u + 1) / 2 < digitIdx u := by have := pu.1; omega
          have hm_62 : (digitIdx l + digitIdx u + 1) / 2 < 62 := by have := pu.1; omega
          have pm := digitByte_props ((digitIdx l + digitIdx u + 1) / 2) hm_62
          have hnz : (digitByte ((digitIdx l + digitIdx u + 1) / 2) != 48) = true := by
            have : (digitIdx l + digitIdx u + 1) / 2 ≠ 0 := by omega
            simp [bne, pm.2.2, this]
          refine ⟨by rw [ValidNonempty, pm.1, hnz]; rfl, ?_, ?_⟩
          · simp only [List.compareLex_cons_cons]
            have hcmp : Ord.compare l (digitByte ((digitIdx l + digitIdx u + 1) / 2)) = .lt := by
              rw [digit_compare_idx _ _ hl_digit pm.1, pm.2.1, nat_compare_iff]
              simp [hm_lo]
            rw [hcmp]; rfl
          · simp only [List.compareLex_cons_cons]
            have hcmp : Ord.compare (digitByte ((digitIdx l + digitIdx u + 1) / 2)) u = .lt := by
              rw [digit_compare_idx _ _ pm.1 hu_digit, pm.2.1, nat_compare_iff]
              simp [hm_hi]
            rw [hcmp]; rfl
        · simp only [hgap, ↓reduceIte]
          cases uRest with
          | nil =>
            simp only [List.isEmpty_nil, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
            rw [pl.2.1]
            have ha := afterKeyBytes_spec lRest hlRest
            refine ⟨validNonempty_cons_of_nonempty l (afterKeyBytes lRest) hl_digit ha.1, ?_, ?_⟩
            · simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, ha.2]
            · simp only [List.compareLex_cons_cons]
              have hcmp : Ord.compare l u = .lt := by
                rw [digit_compare_idx _ _ hl_digit hu_digit, nat_compare_iff]
                simp [hlow_lt_high]
              rw [hcmp]; rfl
          | cons ur urs =>
            simp only [List.isEmpty_cons, Bool.not_false, ↓reduceIte]
            have hnz : (u != 48) = true := by
              have : digitIdx u ≠ 0 := by omega
              simp [bne, pu.2.2.1, this]
            refine ⟨by rw [ValidNonempty, hu_digit, hnz]; rfl, ?_, ?_⟩
            · simp only [List.compareLex_cons_cons]
              have hcmp : Ord.compare l u = .lt := by
                rw [digit_compare_idx _ _ hl_digit hu_digit, nat_compare_iff]
                simp [hlow_lt_high]
              rw [hcmp]; rfl
            · rw [List.compareLex_cons_cons, Std.ReflCmp.compare_self (cmp := Ord.compare) (a := u)]; rfl

    theorem midpointBytes_spec (lower upper : List UInt8)
        (hl : ValidOrEmpty lower = true)
        (hu : ValidNonempty upper = true)
        (hlu : List.compareLex Ord.compare lower upper = .lt) :
        let mid := midpointBytes lower upper
        ValidNonempty mid = true ∧
        List.compareLex Ord.compare lower mid = .lt ∧
        List.compareLex Ord.compare mid upper = .lt := by
      induction upper generalizing lower with
      | nil => simp [ValidNonempty] at hu
      | cons u uRest ih =>
        cases lower with
        | nil =>
          simp only [midpointBytes]
          by_cases hu48 : u == 48
          · simp only [hu48, ↓reduceIte]
            have heq48 : u = 48 := eq_of_beq hu48
            subst heq48
            have huRest_valid : ValidNonempty uRest = true := by
              cases uRest with
              | nil => simp [ValidNonempty] at hu
              | cons a as => simp [ValidNonempty] at hu; exact hu.2
            have hnil_lt : List.compareLex Ord.compare [] uRest = .lt := by
              cases uRest with
              | nil => simp [ValidNonempty] at huRest_valid
              | cons _ _ => rfl
            have sub := ih [] rfl huRest_valid hnil_lt
            refine ⟨validNonempty_cons_of_nonempty 48 _ (by decide) sub.1, rfl, ?_⟩
            simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, sub.2.2]
          · simp only [hu48, Bool.false_eq_true, ↓reduceIte]
            exact stepBytes_spec [] u uRest rfl hu hlu (by intro _ _ h; cases h)
              (fun _ h => htop_absurd hu48 h)
        | cons c lRest =>
          simp only [midpointBytes]
          by_cases huc : u == c
          · simp only [huc, ↓reduceIte]
            have heqc : u = c := eq_of_beq huc
            subst heqc
            obtain ⟨hc_digit, hlRest⟩ := validOrEmpty_cons_inv hl
            have hlt_rest : List.compareLex Ord.compare lRest uRest = .lt := by
              simpa [List.compareLex_cons_cons, Std.ReflCmp.compare_self] using hlu
            have huRest_valid : ValidNonempty uRest = true := by
              cases uRest with
              | nil => cases lRest <;> cases hlt_rest
              | cons a as => simp [ValidNonempty] at hu; exact hu.2
            have sub := ih lRest hlRest huRest_valid hlt_rest
            refine ⟨validNonempty_cons_of_nonempty u _ hc_digit sub.1, ?_, ?_⟩
            · simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, sub.2.1]
            · simp [List.compareLex_cons_cons, Std.ReflCmp.compare_self, sub.2.2]
          · simp only [huc, Bool.false_eq_true, ↓reduceIte]
            exact stepBytes_spec (c :: lRest) u uRest hl hu hlu
              (fun c' l' heq h => by injection heq with hc _; subst hc; exact huc (beq_iff_eq.mpr h))
              (by intro h; cases h)
    where
      htop_absurd {a b : UInt8} (h1 : ¬(a == b) = true) (h2 : a = b) : False :=
        h1 (beq_iff_eq.mpr h2)

    end PositionProof
    """)

    law(open_bounds_default,
      expects: Position.between(nil, nil) == {:ok, "V"},
      proof: ~LEAN"""
      simp [«open_bounds_default:ensures/0», Elixir.Ankole.Pod.Position.«between/2»,
        Elixir.Ankole.Pod.Position.«valid?/1», Elixir.Ankole.Pod.Position.«midpoint/2»,
        Elixir.Ankole.Pod.Position.«after_key/1», Erlang.erlang.«==/2»]
      """
    )

    law(between_complete_spec(lower, upper),
      requires: spec_bound?(lower) and spec_bound?(upper),
      expects: expected_between?(lower, upper, Position.between(lower, upper)),
      proof: ~LEAN"""
      have sim_digit (b : UInt8) :
          Elixir.Ankole.Pod.Position.«digit_byte?/1» (.integer b.toNat) =
            .ok (if PositionProof.isDigit b then Lynx.Term.true else Lynx.Term.false) ∧
          «spec_digit?/1» (.integer b.toNat) =
            .ok (if PositionProof.isDigit b then Lynx.Term.true else Lynx.Term.false) := by
        have hd : Elixir.Ankole.Pod.Position.«digit_byte?/1» (.integer b.toNat) =
            .ok (if PositionProof.isDigit b then Lynx.Term.true else Lynx.Term.false) := by
          simp only [Elixir.Ankole.Pod.Position.«digit_byte?/1», PositionProof.isDigit,
            Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
            Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.true, Lynx.Term.false]
          by_cases h1 : (48 : Int) ≤ b.toNat
          · by_cases h2 : (b.toNat : Int) ≤ 57
            · have n1 : 48 ≤ b.toNat := by omega
              have n2 : b.toNat ≤ 57 := by omega
              simp [h1, h2, n1, n2]
            · by_cases h3 : (65 : Int) ≤ b.toNat
              · by_cases h4 : (b.toNat : Int) ≤ 90
                · have n2 : ¬ (b.toNat ≤ 57) := by omega
                  have n3 : 65 ≤ b.toNat := by omega
                  have n4 : b.toNat ≤ 90 := by omega
                  simp [h1, h2, h3, h4, n2, n3, n4]
                · by_cases h5 : (97 : Int) ≤ b.toNat
                  · by_cases h6 : (b.toNat : Int) ≤ 122
                    · have n2 : ¬ (b.toNat ≤ 57) := by omega
                      have n4 : ¬ (b.toNat ≤ 90) := by omega
                      have n5 : 97 ≤ b.toNat := by omega
                      have n6 : b.toNat ≤ 122 := by omega
                      simp [h1, h2, h3, h4, h5, h6, n2, n4, n5, n6]
                    · have n2 : ¬ (b.toNat ≤ 57) := by omega
                      have n4 : ¬ (b.toNat ≤ 90) := by omega
                      have n6 : ¬ (b.toNat ≤ 122) := by omega
                      simp [h1, h2, h3, h4, h5, h6, n2, n4, n6]
                  · have n2 : ¬ (b.toNat ≤ 57) := by omega
                    have n4 : ¬ (b.toNat ≤ 90) := by omega
                    have n5 : ¬ (97 ≤ b.toNat) := by omega
                    simp [h1, h2, h3, h4, h5, n2, n4, n5]
              · have n2 : ¬ (b.toNat ≤ 57) := by omega
                have n3 : ¬ (65 ≤ b.toNat) := by omega
                have n5 : ¬ (97 ≤ b.toNat) := by omega
                have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
                simp [h1, h2, h3, h5, n2, n3, n5]
          · have h3 : ¬ ((65 : Int) ≤ b.toNat) := by omega
            have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
            have n1 : ¬ (48 ≤ b.toNat) := by omega
            have n3 : ¬ (65 ≤ b.toNat) := by omega
            have n5 : ¬ (97 ≤ b.toNat) := by omega
            simp [h1, h3, h5, n1, n3, n5]
        exact ⟨hd, hd⟩
      have sim_idx (b : UInt8) (hb : PositionProof.isDigit b = true) :
          Elixir.Ankole.Pod.Position.«digit_index/1» (.integer b.toNat) =
            .ok (.integer (PositionProof.digitIdx b)) := by
        simp only [PositionProof.isDigit, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hb
        simp only [Elixir.Ankole.Pod.Position.«digit_index/1», PositionProof.digitIdx,
          Erlang.erlang.«is_integer/1», Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
          Erlang.erlang.«-/2_integers», Erlang.erlang.«+/2_integers»,
          Lynx.Except.andAlso_eq, Lynx.Except.ok_bind, Lynx.Term.true, Lynx.Term.false]
        rcases hb with (⟨h1, h2⟩ | ⟨h1, h2⟩) | ⟨h1, h2⟩
        · have i1 : (48 : Int) ≤ b.toNat := by omega
          have i2 : (b.toNat : Int) ≤ 57 := by omega
          simp [h2, i1, i2]; omega
        · have n2 : ¬ (b.toNat ≤ 57) := by omega
          have i1 : (48 : Int) ≤ b.toNat := by omega
          have in2 : ¬ ((b.toNat : Int) ≤ 57) := by omega
          have i3 : (65 : Int) ≤ b.toNat := by omega
          have i4 : (b.toNat : Int) ≤ 90 := by omega
          simp [n2, h2, i1, in2, i3, i4]; omega
        · have n2 : ¬ (b.toNat ≤ 57) := by omega
          have n4 : ¬ (b.toNat ≤ 90) := by omega
          have i1 : (48 : Int) ≤ b.toNat := by omega
          have in2 : ¬ ((b.toNat : Int) ≤ 57) := by omega
          have i3 : (65 : Int) ≤ b.toNat := by omega
          have in4 : ¬ ((b.toNat : Int) ≤ 90) := by omega
          have i5 : (97 : Int) ≤ b.toNat := by omega
          have i6 : (b.toNat : Int) ≤ 122 := by omega
          simp [n2, n4, i1, in2, i3, in4, i5, i6]; omega
      have sim_byte (i : Nat) (hi : i < 62) :
          Elixir.Ankole.Pod.Position.«digit_byte/1» (.integer i) =
            .ok (.integer (PositionProof.digitByte i).toNat) := by
        simp only [Elixir.Ankole.Pod.Position.«digit_byte/1», PositionProof.digitByte,
          Erlang.erlang.«>=/2_integers», Erlang.erlang.«</2_integers»,
          Erlang.erlang.«+/2_integers», Erlang.erlang.«-/2_integers»,
          Lynx.Except.andAlso_eq, Lynx.Except.ok_bind, Lynx.Term.true, Lynx.Term.false]
        by_cases h1 : i < 10
        · have i0 : (0 : Int) ≤ i := by omega
          have i1 : (i : Int) < 10 := by omega
          simp [h1, i0, i1]; omega
        · by_cases h2 : i < 36
          · have i0 : (0 : Int) ≤ i := by omega
            have in1 : ¬ ((i : Int) < 10) := by omega
            have i2 : (10 : Int) ≤ i := by omega
            have i3 : (i : Int) < 36 := by omega
            have ueq : (UInt8.ofNat (65 + i - 10)).toNat = 65 + i - 10 :=
              UInt8.toNat_ofNat_of_lt (show 65 + i - 10 < 256 by omega)
            simp [h1, h2, i0, in1, i2, i3, ueq]; omega
          · have i0 : (0 : Int) ≤ i := by omega
            have in1 : ¬ ((i : Int) < 10) := by omega
            have i2 : (10 : Int) ≤ i := by omega
            have in3 : ¬ ((i : Int) < 36) := by omega
            have i4 : (36 : Int) ≤ i := by omega
            have i5 : (i : Int) < 62 := by omega
            have ueq : (UInt8.ofNat (97 + i - 36)).toNat = 97 + i - 36 :=
              UInt8.toNat_ofNat_of_lt (show 97 + i - 36 < 256 by omega)
            simp [h1, h2, i0, in1, i2, in3, i4, i5, ueq]; omega
      have sim_valid_bytes : ∀ bs : List UInt8,
          Elixir.Ankole.Pod.Position.«valid_nonempty?/1» (PositionProof.bin bs) =
            .ok (if PositionProof.ValidNonempty bs then Lynx.Term.true else Lynx.Term.false) ∧
          «spec_valid_bytes?/1» (PositionProof.bin bs) =
            .ok (if PositionProof.ValidNonempty bs then Lynx.Term.true else Lynx.Term.false) := by
        intro bs
        induction bs with
        | nil =>
          rw [Elixir.Ankole.Pod.Position.«valid_nonempty?/1».eq_def, «spec_valid_bytes?/1».eq_def]
          simp [Lynx.Term.Bitstring.extract, PositionProof.ValidNonempty]
        | cons b rest ih =>
          rcases rest with _ | ⟨c, cs⟩
          · rw [Elixir.Ankole.Pod.Position.«valid_nonempty?/1».eq_def, «spec_valid_bytes?/1».eq_def]
            simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_nil,
              Lynx.Term.Bitstring.extract, PositionProof.ValidNonempty]
            by_cases hb48 : b = 48
            · subst hb48; simp
            · have hne : Lynx.Term.integer b.toNat ≠ Lynx.Term.integer (48 : UInt8).toNat :=
                PositionProof.int_ne_of_uint8_ne hb48
              have hne_b : (b != 48) = true := by simp [bne, hb48]
              constructor
              · split
                · rename_i heq; exact False.elim (hne heq)
                · simp only [hne_b, Bool.and_true]; exact (sim_digit b).1
              · split
                · rename_i heq; exact False.elim (hne heq)
                · simp only [hne_b, Bool.and_true]; exact (sim_digit b).2
          · rw [Elixir.Ankole.Pod.Position.«valid_nonempty?/1».eq_def, «spec_valid_bytes?/1».eq_def]
            simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_cons,
              PositionProof.matchTail_bin, Lynx.Term.Bitstring.extract, PositionProof.ValidNonempty]
            by_cases hdig : PositionProof.isDigit b = true
            · have hd := sim_digit b
              simp only [hdig, Bool.true_and, ↓reduceIte] at hd ⊢
              constructor
              · split <;> simp only [hd.1, Lynx.Except.ok_bind, ih.1, Lynx.Term.true]
              · split <;> simp only [hd.2, Lynx.Except.ok_bind, ih.2, Lynx.Term.true]
            · have hd := sim_digit b
              have hdigf : PositionProof.isDigit b = false := Bool.eq_false_iff.mpr hdig
              simp only [hdigf, Bool.false_and, Bool.false_eq_true, ↓reduceIte] at hd ⊢
              constructor
              · split <;> simp only [hd.1, Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.false]
              · split <;> simp only [hd.2, Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.false]
      have sim_raise_last : ∀ bs : List UInt8, PositionProof.ValidOrEmpty bs = true →
          Elixir.Ankole.Pod.Position.«raise_last/1» (PositionProof.bin bs) =
            match PositionProof.raiseLastBytes bs with
            | some raised => .ok (.tuple #[.atom "ok", PositionProof.bin raised])
            | none => .ok (.atom "all_top") := by
        intro bs hbs
        induction bs with
        | nil =>
          rw [Elixir.Ankole.Pod.Position.«raise_last/1».eq_def]
          simp [PositionProof.raiseLastBytes]
        | cons b rest ih =>
          obtain ⟨hb, hrest⟩ := PositionProof.validOrEmpty_cons_inv hbs
          have ih' := ih hrest
          rw [Elixir.Ankole.Pod.Position.«raise_last/1».eq_def]
          simp only [PositionProof.matchEnd_cons, PositionProof.matchInteger_cons,
            PositionProof.matchTail_bin, Lynx.Term.Bitstring.extract, PositionProof.raiseLastBytes]
          by_cases hb122 : b = 122
          · subst hb122
            simp only [beq_self_eq_true, ↓reduceIte]
            rw [ih']
            cases PositionProof.raiseLastBytes rest with
            | none => rfl
            | some raised =>
              have seg122 : Lynx.Term.Bitstring.integerSegment (.integer 122) (.integer 8) 1 false =
                  .ok (PositionProof.bin [122]) := PositionProof.integerSegment_bin 122
              simp [Except.bind, seg122]
          · have hbeq : (b == 122) = false := beq_false_of_ne hb122
            have hne_int : Lynx.Term.integer b.toNat ≠ Lynx.Term.integer (122 : UInt8).toNat :=
              PositionProof.int_ne_of_uint8_ne hb122
            rw [hbeq]
            simp only [Bool.false_eq_true, ↓reduceIte]
            split
            · rename_i heq; exact False.elim (hne_int heq)
            · rw [ih']
              cases PositionProof.raiseLastBytes rest with
              | some raised => simp [Except.bind]
              | none =>
                have pb := PositionProof.digit_props b hb
                have hlt61 : PositionProof.digitIdx b < 61 := by
                  have : PositionProof.digitIdx b ≠ 61 := by
                    intro heq; rw [pb.2.2.2] at hbeq; simp [heq] at hbeq
                  have := pb.1; omega
                simp only [Lynx.Except.ok_bind, sim_idx b hb, Erlang.erlang.«+/2_integers»,
                  Lynx.Except.pure_eq_ok]
                have hcast : (PositionProof.digitIdx b : Int) + 1 =
                    ((PositionProof.digitIdx b + 1 : Nat) : Int) := by omega
                rw [hcast, sim_byte (PositionProof.digitIdx b + 1) (by omega)]
                simp
      have sim_after_key : ∀ bs : List UInt8, PositionProof.ValidOrEmpty bs = true →
          Elixir.Ankole.Pod.Position.«after_key/1» (PositionProof.bin bs) =
            .ok (PositionProof.bin (PositionProof.afterKeyBytes bs)) := by
        intro bs hbs
        cases bs with
        | nil => rfl
        | cons b rest =>
          simp only [Elixir.Ankole.Pod.Position.«after_key/1», PositionProof.afterKeyBytes]
          have hbin_eq : (Lynx.Term.bitstring ⟨⟨b :: rest⟩⟩ 0 (Lynx.Term.Bitstring.valid_aligned _)) =
              PositionProof.bin (b :: rest) := rfl
          have seg86 : Lynx.Term.Bitstring.integerSegment (.integer 86) (.integer 8) 1 false =
              .ok (PositionProof.bin [86]) := PositionProof.integerSegment_bin 86
          rw [hbin_eq, sim_raise_last (b :: rest) hbs]
          cases PositionProof.raiseLastBytes (b :: rest) with
          | some raised => rfl
          | none => simp [Except.bind, seg86]
      have sim_step : ∀ (l : List UInt8) (u : UInt8) (uRest : List UInt8),
          PositionProof.ValidOrEmpty l = true →
          PositionProof.isDigit u = true →
          Elixir.Ankole.Pod.Position.«step/3» (PositionProof.bin l) (.integer u.toNat) (PositionProof.bin uRest) =
            .ok (PositionProof.bin (PositionProof.stepBytes l u uRest)) := by
        intro l u uRest hl hu
        have pu := PositionProof.digit_props u hu
        cases l with
        | nil =>
          simp only [Elixir.Ankole.Pod.Position.«step/3», PositionProof.stepBytes,
            PositionProof.matchEnd_nil, Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
            sim_idx u hu, Erlang.erlang.«-/2_integers», PositionProof.gt_integers,
            Int.sub_zero, Nat.sub_zero, Nat.zero_add]
          have hbin_empty : (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) = PositionProof.bin [] := rfl
          by_cases hgap : PositionProof.digitIdx u > 1
          · have hgap_int : (1 : Int) < (PositionProof.digitIdx u : Int) := by omega
            simp only [hgap, hgap_int, ↓reduceIte, Lynx.Term.true, Lynx.Except.ok_bind,
              Erlang.erlang.«+/2_integers», Int.zero_add]
            have hsum : (PositionProof.digitIdx u : Int) + 1 =
                ((PositionProof.digitIdx u + 1 : Nat) : Int) := by omega
            rw [hsum, PositionProof.div_nat_two]
            simp only [Lynx.Except.ok_bind]
            rw [sim_byte ((PositionProof.digitIdx u + 1) / 2) (by have := pu.1; omega)]
            simp
          · have hgap_int : ¬ ((1 : Int) < (PositionProof.digitIdx u : Int)) := by omega
            simp only [hgap, hgap_int, ↓reduceIte, Lynx.Term.false,
              PositionProof.byte_size_bin, Lynx.Except.ok_bind, PositionProof.gt_integers]
            cases uRest with
            | nil =>
              have hlen0 : ¬ ((0 : Int) < (([ ] : List UInt8).length : Int)) := by decide
              have hdb0 : Elixir.Ankole.Pod.Position.«digit_byte/1» (.integer 0) =
                  .ok (.integer (PositionProof.digitByte 0).toNat) := sim_byte 0 (by decide)
              simp only [hlen0, List.isEmpty_nil, Bool.not_true, ↓reduceIte,
                Lynx.Except.ok_bind, hbin_empty, hdb0, sim_after_key [] rfl]
              simp [Except.bind]
            | cons ur urs =>
              have hlen : (0 : Int) < ((ur :: urs).length : Int) := by simp
              simp only [hlen, List.isEmpty_cons, Bool.not_false, ↓reduceIte, Lynx.Term.true]
              exact PositionProof.integerSegment_bin u
        | cons c lRest =>
          obtain ⟨hc, hlRest⟩ := PositionProof.validOrEmpty_cons_inv hl
          have pc := PositionProof.digit_props c hc
          simp only [Elixir.Ankole.Pod.Position.«step/3», PositionProof.stepBytes,
            PositionProof.matchEnd_cons, PositionProof.matchInteger_cons,
            PositionProof.matchTail_bin, Lynx.Term.Bitstring.extract,
            sim_idx c hc, sim_idx u hu, Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
            Erlang.erlang.«-/2_integers», PositionProof.gt_integers]
          by_cases hgap : PositionProof.digitIdx u - PositionProof.digitIdx c > 1
          · have hgap_int : (1 : Int) < (PositionProof.digitIdx u : Int) - (PositionProof.digitIdx c : Int) := by omega
            simp only [hgap, hgap_int, ↓reduceIte, Lynx.Term.true, Lynx.Except.ok_bind,
              Erlang.erlang.«+/2_integers»]
            have hsum : (PositionProof.digitIdx c : Int) + (PositionProof.digitIdx u : Int) + 1 =
                ((PositionProof.digitIdx c + PositionProof.digitIdx u + 1 : Nat) : Int) := by omega
            rw [hsum, PositionProof.div_nat_two]
            simp only [Lynx.Except.ok_bind]
            rw [sim_byte ((PositionProof.digitIdx c + PositionProof.digitIdx u + 1) / 2)
              (by have := pu.1; have := pc.1; omega)]
            simp
          · have hgap_int : ¬ ((1 : Int) < (PositionProof.digitIdx u : Int) - (PositionProof.digitIdx c : Int)) := by omega
            simp only [hgap, hgap_int, ↓reduceIte, Lynx.Term.false,
              PositionProof.byte_size_bin, Lynx.Except.ok_bind, PositionProof.gt_integers]
            cases uRest with
            | nil =>
              have hlen0 : ¬ ((0 : Int) < (([ ] : List UInt8).length : Int)) := by decide
              simp only [hlen0, List.isEmpty_nil, Bool.not_true, Bool.false_eq_true,
                ↓reduceIte, Lynx.Except.ok_bind,
                sim_byte (PositionProof.digitIdx c) pc.1, sim_after_key lRest hlRest]
              simp [Except.bind]
            | cons ur urs =>
              have hlen : (0 : Int) < ((ur :: urs).length : Int) := by simp
              simp only [hlen, List.isEmpty_cons, Bool.not_false, ↓reduceIte, Lynx.Term.true]
              exact PositionProof.integerSegment_bin u
      have sim_midpoint : ∀ (l u : List UInt8),
          PositionProof.ValidOrEmpty l = true →
          PositionProof.ValidNonempty u = true →
          List.compareLex Ord.compare l u = .lt →
          Elixir.Ankole.Pod.Position.«midpoint/2» (PositionProof.bin l) (PositionProof.bin u) =
            .ok (PositionProof.bin (PositionProof.midpointBytes l u)) := by
        intro l u
        induction u generalizing l with
        | nil => intro _ hu _; simp [PositionProof.ValidNonempty] at hu
        | cons u0 uRest ih =>
          intro hl hu hlu
          have hu_digit : PositionProof.isDigit u0 = true :=
            (PositionProof.validOrEmpty_cons_inv (show PositionProof.ValidOrEmpty (u0 :: uRest) = true from hu)).1
          rw [Elixir.Ankole.Pod.Position.«midpoint/2».eq_def]
          cases l with
          | nil =>
            simp only [PositionProof.matchInteger_nil, PositionProof.matchEnd_nil,
              PositionProof.matchInteger_cons, PositionProof.matchTail_bin,
              Lynx.Term.Bitstring.extract, PositionProof.midpointBytes]
            by_cases hu48 : u0 = 48
            · subst hu48
              simp only [beq_self_eq_true, ↓reduceIte]
              have huRest_valid : PositionProof.ValidNonempty uRest = true := by
                cases uRest with
                | nil => simp [PositionProof.ValidNonempty] at hu
                | cons a as => simp [PositionProof.ValidNonempty] at hu; exact hu.2
              have hnil_lt : List.compareLex Ord.compare [] uRest = .lt := by
                cases uRest with
                | nil => simp [PositionProof.ValidNonempty] at huRest_valid
                | cons _ _ => rfl
              have ih' := ih [] rfl huRest_valid hnil_lt
              have hbin_empty : (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) = PositionProof.bin [] := rfl
              have seg48 : Lynx.Term.Bitstring.integerSegment (.integer 48) (.integer 8) 1 false =
                  .ok (PositionProof.bin [48]) := PositionProof.integerSegment_bin 48
              rw [hbin_empty, ih']
              simp [Except.bind, seg48]
            · have hbeq : (u0 == 48) = false := beq_false_of_ne hu48
              have hne_int : Lynx.Term.integer u0.toNat ≠ Lynx.Term.integer (48 : UInt8).toNat :=
                PositionProof.int_ne_of_uint8_ne hu48
              rw [hbeq]; simp only [Bool.false_eq_true, ↓reduceIte]
              have hfall :
                  (match Lynx.Term.integer u0.toNat with
                  | Lynx.Term.integer 48 =>
                    do
                      let _3 ← Elixir.Ankole.Pod.Position.«midpoint/2» (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) (PositionProof.bin uRest)
                      Except.bind (Lynx.Term.Bitstring.integerSegment (.integer 48) (.integer 8) 1 false)
                        (fun s => Except.bind (Lynx.Term.Bitstring.binarySegment _3 (.atom "all") 8)
                          (fun t => Lynx.Term.Bitstring.append s t))
                  | _ => Elixir.Ankole.Pod.Position.«step/3» (PositionProof.bin []) (.integer u0.toNat) (PositionProof.bin uRest)) =
                  Elixir.Ankole.Pod.Position.«step/3» (PositionProof.bin []) (.integer u0.toNat) (PositionProof.bin uRest) := by
                split
                · rename_i heq; exact False.elim (hne_int heq)
                · rfl
              exact hfall.trans (sim_step [] u0 uRest rfl hu_digit)
          | cons c lRest =>
            simp only [PositionProof.matchInteger_cons, PositionProof.matchTail_bin,
              PositionProof.matchEnd_cons, Lynx.Term.Bitstring.extract, PositionProof.midpointBytes,
              Erlang.erlang.«=:=/2», Lynx.Except.guard_ok]
            by_cases huc : u0 = c
            · subst huc
              simp only [beq_self_eq_true, Lynx.Term.exactCompare_self, ↓reduceIte, Lynx.Term.true]
              obtain ⟨_, hlRest⟩ := PositionProof.validOrEmpty_cons_inv hl
              have hlt_rest : List.compareLex Ord.compare lRest uRest = .lt := by
                simpa [List.compareLex_cons_cons, Std.ReflCmp.compare_self] using hlu
              have huRest_valid : PositionProof.ValidNonempty uRest = true := by
                cases uRest with
                | nil => cases lRest <;> cases hlt_rest
                | cons a as => simp [PositionProof.ValidNonempty] at hu; exact hu.2
              rw [ih lRest hlRest huRest_valid hlt_rest]
              simp [Except.bind]
            · have hbeq : (u0 == c) = false := beq_false_of_ne huc
              have hne_exact : ¬ (Lynx.Term.exactCompare (.integer u0.toNat) (.integer c.toNat) = .eq) := by
                rw [Lynx.Term.exactCompare_eq_integer]
                exact PositionProof.int_ne_of_uint8_ne huc
              simp only [hbeq, hne_exact, Bool.false_eq_true, ↓reduceIte, Lynx.Term.false]
              exact sim_step (c :: lRest) u0 uRest hl hu_digit
      have spec_bound_bool : ∀ t : Lynx.Term,
          «spec_bound?/1» t = .ok Lynx.Term.true ∨ «spec_bound?/1» t = .ok Lynx.Term.false := by
        intro t
        cases t with
        | atom s =>
          by_cases hs : s = "nil"
          · subst hs; left; rfl
          · right; simp [«spec_bound?/1», hs]
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; left; rfl
          · right; simp [«spec_bound?/1», hl]
        | _ => right; rfl
      have ⟨hl_bound, hu_bound⟩ :
          «spec_bound?/1» lower = .ok Lynx.Term.true ∧ «spec_bound?/1» upper = .ok Lynx.Term.true := by
        rcases spec_bound_bool lower with hl | hl
        · refine ⟨hl, ?_⟩
          simpa [«between_complete_spec:requires/2», hl] using requires
        · simp [«between_complete_spec:requires/2», hl] at requires
      have classify : ∀ t : Lynx.Term, «spec_bound?/1» t = .ok Lynx.Term.true →
          (t = .atom "nil" ∧
            «spec_valid_key?/1» t = .ok Lynx.Term.false ∧
            «spec_valid_or_empty?/1» t = .ok Lynx.Term.false ∧
            Elixir.Ankole.Pod.Position.«valid?/1» t = .ok Lynx.Term.false) ∨
          (t = PositionProof.bin [] ∧
            «spec_valid_key?/1» t = .ok Lynx.Term.false ∧
            «spec_valid_or_empty?/1» t = .ok Lynx.Term.true ∧
            Elixir.Ankole.Pod.Position.«valid?/1» t = .ok Lynx.Term.true) ∨
          (∃ b bs, t = PositionProof.bin (b :: bs) ∧
            PositionProof.ValidNonempty (b :: bs) = true ∧
            «spec_valid_key?/1» t = .ok Lynx.Term.true ∧
            «spec_valid_or_empty?/1» t = .ok Lynx.Term.true ∧
            Elixir.Ankole.Pod.Position.«valid?/1» t = .ok Lynx.Term.true) ∨
          (∃ b bs, t = PositionProof.bin (b :: bs) ∧
            PositionProof.ValidNonempty (b :: bs) = false ∧
            «spec_valid_key?/1» t = .ok Lynx.Term.false ∧
            «spec_valid_or_empty?/1» t = .ok Lynx.Term.false ∧
            Elixir.Ankole.Pod.Position.«valid?/1» t = .ok Lynx.Term.false) := by
        intro t ht
        cases t with
        | atom s =>
          by_cases hs : s = "nil"
          · subst hs
            left
            refine ⟨rfl, rfl, rfl, ?_⟩
            simp only [Elixir.Ankole.Pod.Position.«valid?/1»]
            rw [Elixir.Ankole.Pod.Position.«valid_nonempty?/1».eq_def]
            rfl
          · simp [«spec_bound?/1», hs] at ht
        | bitstring bytes last valid =>
          rcases bytes with ⟨⟨bs⟩⟩
          by_cases hlast : last = 0
          · subst hlast
            have hbin : Lynx.Term.bitstring ⟨⟨bs⟩⟩ 0 valid = PositionProof.bin bs := rfl
            rw [hbin]
            cases bs with
            | nil =>
              right; left
              refine ⟨rfl, ?_, rfl, rfl⟩
              simp only [«spec_valid_key?/1», (sim_valid_bytes []).2, PositionProof.ValidNonempty]
              rfl
            | cons b rest =>
              have sv := sim_valid_bytes (b :: rest)
              cases hv : PositionProof.ValidNonempty (b :: rest)
              · right; right; right
                refine ⟨b, rest, rfl, hv, ?_, ?_, ?_⟩
                · simp only [«spec_valid_key?/1», sv.2, hv]; rfl
                · simp only [«spec_valid_or_empty?/1», «spec_valid_key?/1», sv.2, hv]; rfl
                · simp only [Elixir.Ankole.Pod.Position.«valid?/1», sv.1, hv]; rfl
              · right; right; left
                refine ⟨b, rest, rfl, hv, ?_, ?_, ?_⟩
                · simp only [«spec_valid_key?/1», sv.2, hv]; rfl
                · simp only [«spec_valid_or_empty?/1», «spec_valid_key?/1», sv.2, hv]; rfl
                · simp only [Elixir.Ankole.Pod.Position.«valid?/1», sv.1, hv]; rfl
          · simp [«spec_bound?/1», hlast] at ht
        | _ => simp [«spec_bound?/1»] at ht
      have bin_cons_ne_empty : ∀ (b : UInt8) (bs : List UInt8),
          Erlang.erlang.«/=/2» (PositionProof.bin (b :: bs)) (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) =
            .ok Lynx.Term.true := by
        intro b bs
        have h0 : (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) = PositionProof.bin [] := rfl
        rw [h0, Erlang.erlang.«/=/2», PositionProof.compare_bin]
        rfl
      have valid_key_eval : ∀ (bs : List UInt8), PositionProof.ValidNonempty bs = true →
          «spec_valid_key?/1» (PositionProof.bin bs) = .ok Lynx.Term.true := by
        intro bs hv
        simp only [«spec_valid_key?/1», (sim_valid_bytes bs).2, hv, ↓reduceIte]
      simp only [«between_complete_spec:ensures/2»]
      rcases classify lower hl_bound with ⟨rfl, l_vk, l_vo, l_pv⟩ | ⟨rfl, l_vk, l_vo, l_pv⟩ |
          ⟨lb, lbs, rfl, l_hv, l_vk, l_vo, l_pv⟩ | ⟨lb, lbs, rfl, _, l_vk, l_vo, l_pv⟩
      · -- lower = nil
        have h0 : (Lynx.Term.bitstring ⟨#[]⟩ 0 (by decide)) = PositionProof.bin [] := rfl
        have empty_pv : Elixir.Ankole.Pod.Position.«valid?/1» (PositionProof.bin []) = .ok Lynx.Term.true := rfl
        rcases classify upper hu_bound with ⟨rfl, u_vk, _, _⟩ | ⟨rfl, u_vk, _, u_pv⟩ |
            ⟨ub, ubs, rfl, u_hv, u_vk, _, u_pv⟩ | ⟨ub, ubs, rfl, _, u_vk, _, u_pv⟩
        · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            Elixir.Ankole.Pod.Position.«valid?/1», Elixir.Ankole.Pod.Position.«midpoint/2»,
            Elixir.Ankole.Pod.Position.«after_key/1», Erlang.erlang.«==/2»]
        · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            Elixir.Ankole.Pod.Position.«valid?/1», l_vo, u_vk, Erlang.erlang.«==/2»,
            Erlang.erlang.«/=/2»]
        · have hlt0 : List.compareLex Ord.compare [] (ub :: ubs) = .lt := rfl
          have hmid_spec := PositionProof.midpointBytes_spec [] (ub :: ubs) rfl u_hv hlt0
          have hmid_sim := sim_midpoint [] (ub :: ubs) rfl u_hv hlt0
          have hvk_mid := valid_key_eval _ hmid_spec.1
          simp only [Elixir.Ankole.Pod.Position.«between/2», Erlang.erlang.«==/2»,
            PositionProof.compare_eq_atom, ↓reduceIte, Lynx.Term.true, Lynx.Term.false,
            Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, h0,
            empty_pv, u_pv, bin_cons_ne_empty ub ubs,
            Erlang.erlang.«</2», PositionProof.compare_bin, hlt0,
            PositionProof.isMember_nil_false_nil, PositionProof.isMember_true_false_nil,
            Lynx.Except.guard_ok, hmid_sim]
          simp [«expected_between?/3», «valid_before_result?/2»,
            Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
            u_vk, hvk_mid, PositionProof.compare_bin, hmid_spec.2.2]
        · have u_nnil : PositionProof.bin (ub :: ubs) ≠ .atom "nil" := fun h => by cases h
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            h0, empty_pv, u_nnil, u_vk, u_pv, l_vo,
            Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Lynx.Term.isMember]
      · -- lower = ""
        have l_nnil : PositionProof.bin [] ≠ .atom "nil" := fun h => by cases h
        rcases classify upper hu_bound with ⟨rfl, u_vk, _, _⟩ | ⟨rfl, u_vk, _, u_pv⟩ |
            ⟨ub, ubs, rfl, u_hv, u_vk, _, u_pv⟩ | ⟨ub, ubs, rfl, _, u_vk, _, u_pv⟩
        · have hak_spec := PositionProof.afterKeyBytes_spec [] rfl
          have hak_sim := sim_after_key [] rfl
          have hvk_ak := valid_key_eval _ hak_spec.1
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3», «valid_after_result?/2»,
            Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
            Lynx.Term.isMember, Elixir.Ankole.Pod.Position.«midpoint/2», l_pv, hak_sim,
            l_nnil, l_vo, hvk_ak, PositionProof.compare_bin, hak_spec.2]
        · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            l_nnil, l_vo, l_pv, u_vk, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
            Lynx.Term.isMember]
        · have u_nnil : PositionProof.bin (ub :: ubs) ≠ .atom "nil" := fun h => by cases h
          have hlt0 : List.compareLex Ord.compare [] (ub :: ubs) = .lt := rfl
          have hmid_spec := PositionProof.midpointBytes_spec [] (ub :: ubs) rfl u_hv hlt0
          have hmid_sim := sim_midpoint [] (ub :: ubs) rfl u_hv hlt0
          have hvk_mid := valid_key_eval _ hmid_spec.1
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3», «valid_between_result?/3»,
            Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
            Lynx.Term.isMember, l_pv, u_pv, bin_cons_ne_empty ub ubs, hmid_sim,
            l_nnil, u_nnil, l_vo, u_vk, hvk_mid,
            PositionProof.compare_bin, hlt0, hmid_spec.2.1, hmid_spec.2.2]
        · have u_nnil : PositionProof.bin (ub :: ubs) ≠ .atom "nil" := fun h => by cases h
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            l_nnil, l_vo, l_pv, u_nnil, u_vk, u_pv, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
            Lynx.Term.isMember]
      · -- lower = valid nonempty key
        have l_nnil : PositionProof.bin (lb :: lbs) ≠ .atom "nil" := fun h => by cases h
        have l_hor : PositionProof.ValidOrEmpty (lb :: lbs) = true := l_hv
        rcases classify upper hu_bound with ⟨rfl, u_vk, _, _⟩ | ⟨rfl, u_vk, _, u_pv⟩ |
            ⟨ub, ubs, rfl, u_hv, u_vk, _, u_pv⟩ | ⟨ub, ubs, rfl, _, u_vk, _, u_pv⟩
        · have hak_spec := PositionProof.afterKeyBytes_spec (lb :: lbs) l_hor
          have hak_sim := sim_after_key (lb :: lbs) l_hor
          have hvk_ak := valid_key_eval _ hak_spec.1
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3», «valid_after_result?/2»,
            Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
            Lynx.Term.isMember, Elixir.Ankole.Pod.Position.«midpoint/2», l_pv, hak_sim,
            l_nnil, l_vo, hvk_ak, PositionProof.compare_bin, hak_spec.2]
        · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            l_nnil, l_vo, l_pv, u_vk, u_pv, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
            Lynx.Term.isMember]
        · have u_nnil : PositionProof.bin (ub :: ubs) ≠ .atom "nil" := fun h => by cases h
          cases hcmp : List.compareLex Ord.compare (lb :: lbs) (ub :: ubs)
          · have hmid_spec := PositionProof.midpointBytes_spec (lb :: lbs) (ub :: ubs) l_hor u_hv hcmp
            have hmid_sim := sim_midpoint (lb :: lbs) (ub :: ubs) l_hor u_hv hcmp
            have hvk_mid := valid_key_eval _ hmid_spec.1
            simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3», «valid_between_result?/3»,
              Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
              Lynx.Term.isMember, l_pv, u_pv, bin_cons_ne_empty ub ubs, hmid_sim,
              l_nnil, u_nnil, l_vo, u_vk, hvk_mid,
              PositionProof.compare_bin, hcmp, hmid_spec.2.1, hmid_spec.2.2]
          · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
              l_nnil, u_nnil, l_vo, l_pv, u_vk, u_pv,
              Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
              PositionProof.compare_bin, hcmp, Lynx.Term.isMember]
          · simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
              l_nnil, u_nnil, l_vo, l_pv, u_vk, u_pv,
              Erlang.erlang.«==/2», Erlang.erlang.«/=/2», Erlang.erlang.«</2»,
              PositionProof.compare_bin, hcmp, Lynx.Term.isMember]
        · have u_nnil : PositionProof.bin (ub :: ubs) ≠ .atom "nil" := fun h => by cases h
          simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
            l_nnil, l_vo, l_pv, u_nnil, u_vk, u_pv, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
            Lynx.Term.isMember]
      · -- lower = invalid binary
        have l_nnil : PositionProof.bin (lb :: lbs) ≠ .atom "nil" := fun h => by cases h
        simp [Elixir.Ankole.Pod.Position.«between/2», «expected_between?/3»,
          l_nnil, l_vo, l_pv, Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
          Lynx.Term.isMember]
      """
    )

    law(invalid_lower_rejected(lower, upper),
      requires:
        spec_bound?(lower) and spec_bound?(upper) and not is_nil(lower) and
          not spec_valid_or_empty?(lower),
      expects: Position.between(lower, upper) == :error,
      proof: ~LEAN"""
      have sb_bool : ∀ t : Lynx.Term,
          «spec_bound?/1» t = .ok Lynx.Term.true ∨ «spec_bound?/1» t = .ok Lynx.Term.false := by
        intro t
        cases t with
        | atom s =>
          by_cases hs : s = "nil"
          · subst hs; left; rfl
          · right; simp [«spec_bound?/1», hs]
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; left; rfl
          · right; simp [«spec_bound?/1», hl]
        | _ => right; rfl
      rcases sb_bool lower with hbl | hbl
      · rcases sb_bool upper with hbu | hbu
        · have master := «between_complete_spec/2» lower upper
            (by simp [«between_complete_spec:requires/2», hbl, hbu])
          by_cases hnil : lower = .atom "nil"
          · subst hnil
            simp [«invalid_lower_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu] at requires
          · have req' : (do let _3 ← «spec_valid_or_empty?/1» lower; Erlang.erlang.«not/1» _3) = .ok Lynx.Term.true := by
              simpa [«invalid_lower_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu, hnil] using requires
            rw [Lynx.Except.bind_eq_ok] at req'
            obtain ⟨v, hv, hnot⟩ := req'
            have hvf : v = Lynx.Term.false := by
              cases v <;> simp [Erlang.erlang.«not/1»] at hnot
              rename_i s; by_cases hs : s = "false" <;> simp_all
              by_cases hs2 : s = "true" <;> simp_all
            subst hvf
            simpa [«between_complete_spec:ensures/2», «invalid_lower_rejected:ensures/2»,
              «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
              hnil, hv] using master
        · simp [«invalid_lower_rejected:requires/2», hbl, hbu] at requires
      · simp [«invalid_lower_rejected:requires/2», hbl] at requires
      """
    )

    law(invalid_upper_rejected(lower, upper),
      requires:
        spec_bound?(lower) and spec_bound?(upper) and not is_nil(upper) and
          not spec_valid_key?(upper),
      expects: Position.between(lower, upper) == :error,
      proof: ~LEAN"""
      have sb_bool : ∀ t : Lynx.Term,
          «spec_bound?/1» t = .ok Lynx.Term.true ∨ «spec_bound?/1» t = .ok Lynx.Term.false := by
        intro t
        cases t with
        | atom s =>
          by_cases hs : s = "nil"
          · subst hs; left; rfl
          · right; simp [«spec_bound?/1», hs]
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; left; rfl
          · right; simp [«spec_bound?/1», hl]
        | _ => right; rfl
      have hvo_bool : ∀ t : Lynx.Term, «spec_valid_or_empty?/1» t = .ok Lynx.Term.true ∨
          «spec_valid_or_empty?/1» t = .ok Lynx.Term.false := by
        have sd_bool : ∀ b : UInt8,
            «spec_digit?/1» (.integer b.toNat) = .ok Lynx.Term.true ∨
            «spec_digit?/1» (.integer b.toNat) = .ok Lynx.Term.false := by
          intro b
          simp only [«spec_digit?/1», Erlang.erlang.«is_integer/1»,
            Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
            Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.true, Lynx.Term.false]
          by_cases h1 : (48 : Int) ≤ b.toNat
          · by_cases h2 : (b.toNat : Int) ≤ 57
            · left; simp [h1, h2]
            · by_cases h3 : (65 : Int) ≤ b.toNat
              · by_cases h4 : (b.toNat : Int) ≤ 90
                · left; simp [h1, h2, h3, h4]
                · by_cases h5 : (97 : Int) ≤ b.toNat
                  · by_cases h6 : (b.toNat : Int) ≤ 122
                    · left; simp [h1, h2, h3, h4, h5, h6]
                    · right; simp [h1, h2, h3, h4, h5, h6]
                  · right; simp [h1, h2, h3, h4, h5]
              · have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
                right; simp [h1, h2, h3, h5]
          · have h3 : ¬ ((65 : Int) ≤ b.toNat) := by omega
            have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
            right; simp [h1, h3, h5]
        have sb : ∀ bs : List UInt8,
            «spec_valid_bytes?/1» (PositionProof.bin bs) = .ok Lynx.Term.true ∨
            «spec_valid_bytes?/1» (PositionProof.bin bs) = .ok Lynx.Term.false := by
          intro bs
          induction bs with
          | nil =>
            rw [«spec_valid_bytes?/1».eq_def]
            right; simp [Lynx.Term.Bitstring.extract]
          | cons b rest ih =>
            rcases rest with _ | ⟨c, cs⟩
            · rw [«spec_valid_bytes?/1».eq_def]
              simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_nil, Lynx.Term.Bitstring.extract]
              split
              · right; rfl
              · exact sd_bool b
            · rw [«spec_valid_bytes?/1».eq_def]
              simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_cons,
                PositionProof.matchTail_bin, Lynx.Term.Bitstring.extract]
              rcases sd_bool b with hsd | hsd
              · rcases ih with ih | ih
                · left; split <;> simp only [hsd, Lynx.Except.ok_bind, ih, Lynx.Term.true]
                · right; split <;> simp only [hsd, Lynx.Except.ok_bind, ih, Lynx.Term.true]
              · right; split <;> simp only [hsd, Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.false]
        intro t
        cases t with
        | bitstring bytes last valid =>
          rcases bytes with ⟨⟨bs⟩⟩
          by_cases hl : last = 0
          · subst hl
            cases bs with
            | nil => left; rfl
            | cons b rest => exact sb (b :: rest)
          · right; cases bs <;> simp [«spec_valid_or_empty?/1», «spec_valid_key?/1», hl]
        | _ => right; rfl
      rcases sb_bool lower with hbl | hbl
      · rcases sb_bool upper with hbu | hbu
        · have master := «between_complete_spec/2» lower upper
            (by simp [«between_complete_spec:requires/2», hbl, hbu])
          by_cases hunil : upper = .atom "nil"
          · subst hunil
            simp [«invalid_upper_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu] at requires
          · have req' : (do let _3 ← «spec_valid_key?/1» upper; Erlang.erlang.«not/1» _3) = .ok Lynx.Term.true := by
              simpa [«invalid_upper_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu, hunil] using requires
            rw [Lynx.Except.bind_eq_ok] at req'
            obtain ⟨v, hv, hnot⟩ := req'
            have hvf : v = Lynx.Term.false := by
              cases v <;> simp [Erlang.erlang.«not/1»] at hnot
              rename_i s; by_cases hs : s = "false" <;> simp_all
              by_cases hs2 : s = "true" <;> simp_all
            subst hvf
            by_cases hlnil : lower = .atom "nil"
            · subst hlnil
              have hvo_nil : «spec_valid_or_empty?/1» (.atom "nil") = .ok Lynx.Term.false := rfl
              simpa [«between_complete_spec:ensures/2», «invalid_upper_rejected:ensures/2»,
                «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
                hvo_nil, hunil, hv] using master
            · rcases hvo_bool lower with hvo | hvo <;>
                simpa [«between_complete_spec:ensures/2», «invalid_upper_rejected:ensures/2»,
                  «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
                  hlnil, hunil, hvo, hv] using master
        · simp [«invalid_upper_rejected:requires/2», hbl, hbu] at requires
      · simp [«invalid_upper_rejected:requires/2», hbl] at requires
      """
    )

    law(unordered_bounds_rejected(lower, upper),
      requires:
        spec_bound?(lower) and spec_bound?(upper) and not is_nil(lower) and not is_nil(upper) and
          not (lower < upper),
      expects: Position.between(lower, upper) == :error,
      proof: ~LEAN"""
      have sb_bool : ∀ t : Lynx.Term,
          «spec_bound?/1» t = .ok Lynx.Term.true ∨ «spec_bound?/1» t = .ok Lynx.Term.false := by
        intro t
        cases t with
        | atom s =>
          by_cases hs : s = "nil"
          · subst hs; left; rfl
          · right; simp [«spec_bound?/1», hs]
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; left; rfl
          · right; simp [«spec_bound?/1», hl]
        | _ => right; rfl
      rcases sb_bool lower with hbl | hbl
      · rcases sb_bool upper with hbu | hbu
        · have master := «between_complete_spec/2» lower upper
            (by simp [«between_complete_spec:requires/2», hbl, hbu])
          by_cases hlnil : lower = .atom "nil"
          · subst hlnil
            simp [«unordered_bounds_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu] at requires
          · by_cases hunil : upper = .atom "nil"
            · subst hunil
              simp [«unordered_bounds_rejected:requires/2», Erlang.erlang.«/=/2», hbl, hbu, hlnil] at requires
            · have hge : Erlang.erlang.«>=/2» lower upper = .ok Lynx.Term.true := by
                simpa [«unordered_bounds_rejected:requires/2», Erlang.erlang.«/=/2»,
                  hbl, hbu, hlnil, hunil] using requires
              have hlt_false : Erlang.erlang.«</2» lower upper = .ok Lynx.Term.false := by
                simp only [Erlang.erlang.«>=/2», Erlang.erlang.«</2»] at hge ⊢
                cases hcmp : Lynx.Term.compare lower upper <;> simp [hcmp] at hge ⊢
              have hv_bool : ∀ t : Lynx.Term,
                  («spec_valid_key?/1» t = .ok Lynx.Term.true ∨ «spec_valid_key?/1» t = .ok Lynx.Term.false) ∧
                  («spec_valid_or_empty?/1» t = .ok Lynx.Term.true ∨ «spec_valid_or_empty?/1» t = .ok Lynx.Term.false) := by
                have sd_bool : ∀ b : UInt8,
                    «spec_digit?/1» (.integer b.toNat) = .ok Lynx.Term.true ∨
                    «spec_digit?/1» (.integer b.toNat) = .ok Lynx.Term.false := by
                  intro b
                  simp only [«spec_digit?/1», Erlang.erlang.«is_integer/1»,
                    Erlang.erlang.«>=/2_integers», Erlang.erlang.«=</2_integers»,
                    Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.true, Lynx.Term.false]
                  by_cases h1 : (48 : Int) ≤ b.toNat
                  · by_cases h2 : (b.toNat : Int) ≤ 57
                    · left; simp [h1, h2]
                    · by_cases h3 : (65 : Int) ≤ b.toNat
                      · by_cases h4 : (b.toNat : Int) ≤ 90
                        · left; simp [h1, h2, h3, h4]
                        · by_cases h5 : (97 : Int) ≤ b.toNat
                          · by_cases h6 : (b.toNat : Int) ≤ 122
                            · left; simp [h1, h2, h3, h4, h5, h6]
                            · right; simp [h1, h2, h3, h4, h5, h6]
                          · right; simp [h1, h2, h3, h4, h5]
                      · have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
                        right; simp [h1, h2, h3, h5]
                  · have h3 : ¬ ((65 : Int) ≤ b.toNat) := by omega
                    have h5 : ¬ ((97 : Int) ≤ b.toNat) := by omega
                    right; simp [h1, h3, h5]
                have sb : ∀ bs : List UInt8,
                    «spec_valid_bytes?/1» (PositionProof.bin bs) = .ok Lynx.Term.true ∨
                    «spec_valid_bytes?/1» (PositionProof.bin bs) = .ok Lynx.Term.false := by
                  intro bs
                  induction bs with
                  | nil =>
                    rw [«spec_valid_bytes?/1».eq_def]
                    right; simp [Lynx.Term.Bitstring.extract]
                  | cons b rest ih =>
                    rcases rest with _ | ⟨c, cs⟩
                    · rw [«spec_valid_bytes?/1».eq_def]
                      simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_nil, Lynx.Term.Bitstring.extract]
                      split
                      · right; rfl
                      · exact sd_bool b
                    · rw [«spec_valid_bytes?/1».eq_def]
                      simp only [PositionProof.matchInteger_cons, PositionProof.matchEnd_cons,
                        PositionProof.matchTail_bin, Lynx.Term.Bitstring.extract]
                      rcases sd_bool b with hsd | hsd
                      · rcases ih with ih | ih
                        · left; split <;> simp only [hsd, Lynx.Except.ok_bind, ih, Lynx.Term.true]
                        · right; split <;> simp only [hsd, Lynx.Except.ok_bind, ih, Lynx.Term.true]
                      · right; split <;> simp only [hsd, Lynx.Except.ok_bind, Lynx.Except.pure_eq_ok, Lynx.Term.false]
                intro t
                cases t with
                | bitstring bytes last valid =>
                  rcases bytes with ⟨⟨bs⟩⟩
                  by_cases hl : last = 0
                  · subst hl
                    cases bs with
                    | nil => exact ⟨sb [], Or.inl rfl⟩
                    | cons b rest => exact ⟨sb (b :: rest), sb (b :: rest)⟩
                  · refine ⟨Or.inr (by simp [«spec_valid_key?/1», hl]), Or.inr ?_⟩
                    cases bs <;> simp [«spec_valid_or_empty?/1», «spec_valid_key?/1», hl]
                | _ => exact ⟨Or.inr rfl, Or.inr rfl⟩
              rcases (hv_bool lower).2 with hlo | hlo <;> rcases (hv_bool upper).1 with huk | huk <;>
                simpa [«between_complete_spec:ensures/2», «unordered_bounds_rejected:ensures/2»,
                  «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
                  hlnil, hunil, hlo, huk, hlt_false] using master
        · simp [«unordered_bounds_rejected:requires/2», hbl, hbu] at requires
      · simp [«unordered_bounds_rejected:requires/2», hbl] at requires
      """
    )

    law(open_upper_produces_valid_greater_key(lower),
      requires: spec_valid_key?(lower),
      expects: valid_after_result?(Position.between(lower, nil), lower),
      proof: ~LEAN"""
      have hreq : «spec_valid_key?/1» lower = .ok Lynx.Term.true := requires
      have hbl : «spec_bound?/1» lower = .ok Lynx.Term.true := by
        cases lower with
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; rfl
          · simp [«spec_valid_key?/1», hl] at hreq
        | _ => simp [«spec_valid_key?/1»] at hreq
      have hbnil : «spec_bound?/1» (.atom "nil") = .ok Lynx.Term.true := rfl
      have master := «between_complete_spec/2» lower (.atom "nil")
        (by simp [«between_complete_spec:requires/2», hbl, hbnil])
      have hlnil : lower ≠ .atom "nil" := by rintro rfl; simp [«spec_valid_key?/1»] at hreq
      have hvo : «spec_valid_or_empty?/1» lower = .ok Lynx.Term.true := by
        cases lower with
        | bitstring bytes last valid =>
          rcases bytes with ⟨⟨bs⟩⟩
          cases bs with
          | nil =>
            by_cases hl : last = 0
            · subst hl; rfl
            · simp [«spec_valid_key?/1», hl] at hreq
          | cons _ _ => exact hreq
        | _ => simp [«spec_valid_key?/1»] at hreq
      simpa [«between_complete_spec:ensures/2», «open_upper_produces_valid_greater_key:ensures/1»,
        «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
        hlnil, hvo] using master
      """
    )

    law(open_lower_produces_valid_smaller_key(upper),
      requires: spec_valid_key?(upper),
      expects: valid_before_result?(Position.between(nil, upper), upper),
      proof: ~LEAN"""
      have huv : «spec_valid_key?/1» upper = .ok Lynx.Term.true := requires
      have hbu : «spec_bound?/1» upper = .ok Lynx.Term.true := by
        cases upper with
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; rfl
          · simp [«spec_valid_key?/1», hl] at huv
        | _ => simp [«spec_valid_key?/1»] at huv
      have hbnil : «spec_bound?/1» (.atom "nil") = .ok Lynx.Term.true := rfl
      have master := «between_complete_spec/2» (.atom "nil") upper
        (by simp [«between_complete_spec:requires/2», hbnil, hbu])
      have hunil : upper ≠ .atom "nil" := by rintro rfl; simp [«spec_valid_key?/1»] at huv
      simpa [«between_complete_spec:ensures/2», «open_lower_produces_valid_smaller_key:ensures/1»,
        «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
        hunil, huv] using master
      """
    )

    law(between_produces_valid_strictly_ordered_key(lower, upper),
      requires: spec_valid_key?(lower) and spec_valid_key?(upper) and lower < upper,
      expects: valid_between_result?(Position.between(lower, upper), lower, upper),
      proof: ~LEAN"""
      unfold «between_produces_valid_strictly_ordered_key:requires/2» at requires
      rw [Lynx.Except.bind_eq_ok] at requires
      obtain ⟨b1, hb1, hlt⟩ := requires
      rw [Lynx.Except.bind_eq_ok] at hb1
      obtain ⟨b0, hb0, hb1'⟩ := hb1
      have hb0_true : b0 = Lynx.Term.true := by
        cases b0 with
        | atom s =>
          by_cases hs : s = "true"
          · subst hs; rfl
          · by_cases hsf : s = "false"
            · subst hsf; simp at hb1'; subst hb1'; simp at hlt
            · simp [hs, hsf] at hb1'
        | _ => simp at hb1'
      subst hb0_true
      simp only [Lynx.Term.true] at hb1'
      have hb1_true : b1 = Lynx.Term.true := by
        cases b1 with
        | atom s =>
          by_cases hs : s = "true"
          · subst hs; rfl
          · by_cases hsf : s = "false"
            · subst hsf; simp at hlt
            · simp [hs, hsf] at hlt
        | _ => simp at hlt
      subst hb1_true
      simp only [Lynx.Term.true] at hlt
      have hbl : «spec_bound?/1» lower = .ok Lynx.Term.true := by
        cases lower with
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; rfl
          · simp [«spec_valid_key?/1», hl] at hb0
        | _ => simp [«spec_valid_key?/1»] at hb0
      have hbu : «spec_bound?/1» upper = .ok Lynx.Term.true := by
        cases upper with
        | bitstring _ last _ =>
          by_cases hl : last = 0
          · subst hl; rfl
          · simp [«spec_valid_key?/1», hl] at hb1'
        | _ => simp [«spec_valid_key?/1»] at hb1'
      have master := «between_complete_spec/2» lower upper
        (by simp [«between_complete_spec:requires/2», hbl, hbu])
      have hlnil : lower ≠ .atom "nil" := by rintro rfl; simp [«spec_valid_key?/1»] at hb0
      have hunil : upper ≠ .atom "nil" := by rintro rfl; simp [«spec_valid_key?/1»] at hb1'
      have hvo : «spec_valid_or_empty?/1» lower = .ok Lynx.Term.true := by
        cases lower with
        | bitstring bytes last valid =>
          rcases bytes with ⟨⟨bs⟩⟩
          cases bs with
          | nil =>
            by_cases hl : last = 0
            · subst hl; rfl
            · simp [«spec_valid_key?/1», hl] at hb0
          | cons _ _ => exact hb0
        | _ => simp [«spec_valid_key?/1»] at hb0
      simpa [«between_complete_spec:ensures/2»,
        «between_produces_valid_strictly_ordered_key:ensures/2»,
        «expected_between?/3», Erlang.erlang.«==/2», Erlang.erlang.«/=/2»,
        hlnil, hunil, hvo, hb1', hlt] using master
      """
    )
  end

  test "laws also execute as concrete Elixir assertions" do
    open_bounds_default()
    between_complete_spec(nil, nil)
    between_complete_spec("", nil)
    between_complete_spec("V", "")
    between_complete_spec(<<0xFF>>, "V")
    between_complete_spec("0", "1")
    invalid_lower_rejected("0", nil)
    invalid_lower_rejected(<<0xFF>>, "V")
    invalid_lower_rejected("019a-uuid", "V")
    invalid_upper_rejected("V", "0")
    invalid_upper_rejected(nil, "")
    invalid_upper_rejected("A", <<0xFF>>)
    unordered_bounds_rejected("V", "V")
    unordered_bounds_rejected("z", "A")
    open_upper_produces_valid_greater_key("z")
    open_upper_produces_valid_greater_key("zz")
    open_lower_produces_valid_smaller_key("1")
    open_lower_produces_valid_smaller_key("01")
    between_produces_valid_strictly_ordered_key("A", "B")
    between_produces_valid_strictly_ordered_key("0z", "1")
  end
end
