defmodule Ankole.Brain.AppletFactsTest do
  use Ankole.DataCase

  alias Ankole.Brain.SchemaPacks

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: member} = Ankole.PrincipalsFixtures.human_fixture()
    {:ok, _} = Ankole.Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(member.uid) end)

    {:ok, object} =
      Ankole.Brain.create_object(
        %{
          slug: "concepts/acme-qc",
          type: "concept",
          title: "Acme QC"
        },
        member.uid
      )

    %{member: member, object: object}
  end

  test "applet_write_fact records deterministic Facts with recordRef for both humans and Applet service accounts",
       context do
    actor = Ankole.PrincipalsFixtures.actor_fixture(context.member)

    stranger =
      Ankole.PrincipalsFixtures.human_fixture().principal
      |> Ankole.PrincipalsFixtures.actor_fixture()

    {:ok, source} = Ankole.Pod.Pages.create(actor, %{type: "doc", title: "Inspection Log"})
    {:ok, applet_page} = Ankole.Pod.Pages.create(actor, %{type: "applet", title: "QC Applet"})

    {:ok, svc} =
      Ankole.Principals.get_principal(
        Ankole.Principals.ServiceAccounts.applet_uid(applet_page.id)
      )

    svc_actor = Ankole.AuthZ.Actor.new(svc)

    input = %{
      "sourceNodeId" => source.id,
      "subjectPageId" => context.object.id,
      "claim" => "Batch #402 failed stitch-density inspection at 2.1% defect rate",
      "kind" => "event",
      "notability" => "high",
      "confidence" => 0.93,
      "provenance" => "QC inspection submit",
      "recordRef" => %{"tableId" => "tbl_qc", "recordId" => "rec_402"}
    }

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(context.member.uid, source.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: context.member.uid, role: "manage"}]
      })

    assert {:error, :forbidden} = Ankole.Brain.applet_write_fact(stranger, input)
    assert {:error, :forbidden} = Ankole.Brain.applet_write_fact(svc_actor, input)

    assert {:ok, inserted} = Ankole.Brain.applet_write_fact(actor, input)
    assert inserted.status == "inserted"
    assert inserted.confidence == 0.95
    assert inserted.provenance == "QC inspection submit [base:tbl_qc/rec_402]"
    assert inserted.author == Ankole.ActorRef.from_principal(context.member)

    assert {:ok, dup} = Ankole.Brain.applet_write_fact(actor, input)
    assert dup.status == "duplicate"
    assert dup.id == inserted.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(context.member.uid, source.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: context.member.uid, role: "manage"},
          %{principal_uid: svc.uid, role: "edit"}
        ]
      })

    svc_input =
      Map.merge(input, %{
        "claim" => "Batch #403 passed final rework verification",
        "recordRef" => %{"tableId" => "tbl_qc", "recordId" => "rec_403"}
      })

    assert {:error, :not_found} = Ankole.Brain.applet_write_fact(svc_actor, svc_input)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(context.member.uid, context.object.id, %{
        inherit_permissions: true,
        grants: [%{principal_uid: svc.uid, role: "view"}]
      })

    assert {:ok, svc_fact} = Ankole.Brain.applet_write_fact(svc_actor, svc_input)
    assert svc_fact.status == "inserted"
    assert svc_fact.holder == context.object.id
    assert svc_fact.author == Ankole.ActorRef.from_principal(svc)
    assert svc_fact.provenance == "QC inspection submit [base:tbl_qc/rec_403]"

    svc_update =
      Map.put(svc_input, "claim", "Batch #403 passed rework verification with 0.0% defects")

    assert {:ok, superseded} = Ankole.Brain.applet_write_fact(svc_actor, svc_update)
    assert superseded.status == "superseded"
    assert superseded.id != svc_fact.id
  end

  test "background embedding of a record-tagged fact excludes itself from dedup and recordRef match",
       context do
    alias Ankole.Brain.Claims
    alias Ankole.Brain.Schemas.Claim
    require Ash.Query

    actor = Ankole.PrincipalsFixtures.actor_fixture(context.member)
    {:ok, source} = Ankole.Pod.Pages.create(actor, %{type: "doc", title: "Inspection Embed Log"})

    {:ok, inserted} =
      Ankole.Brain.applet_write_fact(actor, %{
        "sourceNodeId" => source.id,
        "subjectPageId" => context.object.id,
        "claim" => "Batch #404 passed initial verification",
        "kind" => "event",
        "provenance" => "QC inspection submit",
        "recordRef" => %{"tableId" => "tbl_qc", "recordId" => "rec_404"}
      })

    fact = Claim |> Ash.Query.filter(id == ^inserted.id) |> Ankole.Ash.read_one!()
    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

    assert {:ok, :embedded} =
             Repo.transact(fn ->
               Claims.attach_embedding_in_tx(
                 fact,
                 vector,
                 "test-signature",
                 DateTime.utc_now(:microsecond)
               )
             end)

    updated = Claim |> Ash.Query.filter(id == ^inserted.id) |> Ankole.Ash.read_one!()
    assert updated.superseded_by == nil
    assert updated.embedded_at != nil
  end
end
