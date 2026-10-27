defmodule Ankole.Formal.Pod.ActivityLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias AnkoleWeb.PodStream

  laws "Activity terminal epoch contract" do
    prelude(~LEAN"""
    module
    public import Lynx
    public import Lynx.Modules.Erlang.erlang
    import all Lynx.Term.Compare
    @[expose] public section
    namespace ActivityProof
    @[simp] theorem active_not_unavailable :
        Lynx.Term.compare
          (.bitstring ⟨#[97,99,116,105,118,101]⟩ 0 (by decide))
          (.bitstring ⟨#[117,110,97,118,97,105,108,97,98,108,101]⟩ 0 (by decide)) ≠ .eq := by decide
    @[simp] theorem active_not_settled :
        Lynx.Term.compare
          (.bitstring ⟨#[97,99,116,105,118,101]⟩ 0 (by decide))
          (.bitstring ⟨#[115,101,116,116,108,101,100]⟩ 0 (by decide)) ≠ .eq := by decide
    end ActivityProof
    """)

    cutoff(&:elixir_erl_pass.no_parens_remote/2)

    law(settled_epoch_absorbs(epoch, revision, incoming_revision),
      expects:
        PodStream.merge_activity(
          %{epoch: epoch, revision: revision, state: "settled"},
          %{epoch: epoch, revision: incoming_revision, state: "active"},
          true
        ) === {%{epoch: epoch, revision: revision, state: "settled"}, false},
      proof: ~LEAN"""
      simp only [«settled_epoch_absorbs:ensures/3», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind]
      unfold Elixir.AnkoleWeb.PodStream.«merge_activity/3»
      dsimp only
      simp only [Lynx.Term.getMapKeys]
      simp +decide [Erlang.erlang.«==/2», Erlang.erlang.«</2», Erlang.erlang.«=:=/2»,
        Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Lynx.Term.isMember, Std.ReflCmp.compare_self]
      """
    )

    law(older_epoch_is_rejected(older, newer, other),
      requires: older < newer,
      expects:
        PodStream.merge_activity(
          %{epoch: newer, revision: other, state: "active"},
          %{epoch: older, revision: other, state: "active"}
        ) === {%{epoch: newer, revision: other, state: "active"}, false},
      proof: ~LEAN"""
      simp only [«older_epoch_is_rejected:requires/3», Erlang.erlang.«</2»] at requires
      simp only [«older_epoch_is_rejected:ensures/3», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
        Elixir.AnkoleWeb.PodStream.«merge_activity/2»]
      unfold Elixir.AnkoleWeb.PodStream.«merge_activity/3»
      dsimp only
      simp only [Lynx.Term.getMapKeys]
      simp_all [Erlang.erlang.«==/2», Erlang.erlang.«</2», Erlang.erlang.«=:=/2»,
        Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Lynx.Term.isMember, Std.ReflCmp.compare_self]
      """
    )

    law(older_active_revision_is_rejected(older, newer, other),
      requires: older < newer,
      expects:
        PodStream.merge_activity(
          %{epoch: other, revision: newer, state: "active"},
          %{epoch: other, revision: older, state: "active"}
        ) === {%{epoch: other, revision: newer, state: "active"}, false},
      proof: ~LEAN"""
      simp only [«older_active_revision_is_rejected:requires/3», Erlang.erlang.«</2»] at requires
      simp only [«older_active_revision_is_rejected:ensures/3», Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind,
        Elixir.AnkoleWeb.PodStream.«merge_activity/2»]
      unfold Elixir.AnkoleWeb.PodStream.«merge_activity/3»
      dsimp only
      simp only [Lynx.Term.getMapKeys]
      simp_all [Erlang.erlang.«==/2», Erlang.erlang.«</2», Erlang.erlang.«=:=/2»,
        Lynx.Except.pure_eq_ok, Lynx.Except.ok_bind, Lynx.Except.guard,
        Lynx.Term.isMember, Std.ReflCmp.compare_self]
      """
    )
  end
end
