defmodule Ankole.Pod.AppletApprovalsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Pod.{Pages, PagesFixtures}
  alias Ankole.Pod.Applets.Approvals

  setup do
    owner = actor_fixture(human_fixture().principal)
    reviewer = actor_fixture(human_fixture().principal)
    other = actor_fixture(human_fixture().principal)

    {:ok, page} = Pages.create(owner, %{type: :applet, private_owner_uid: owner.principal.uid})

    {:ok, _} =
      PagesFixtures.set_sharing(owner.principal.uid, page.id, %{
        grants: [
          %{principal_uid: reviewer.principal.uid, role: "view"},
          %{principal_uid: other.principal.uid, role: "view"}
        ]
      })

    input = %{
      "requestKey" => "request-17",
      "reviewerUid" => reviewer.principal.uid,
      "summary" => "Check the reported discrepancy",
      "details" => "Review the source against the imported record."
    }

    %{page: page, owner: owner, reviewer: reviewer, other: other, input: input}
  end

  test "request and final decision are durable, attributable and idempotent", ctx do
    assert {:ok, pending} =
             Approvals.request(ctx.page.id, ctx.owner, ctx.owner, ctx.input)

    assert %{status: "pending", note: nil, decidedAt: nil} = pending
    assert pending.requesterUid == ctx.owner.principal.uid
    assert pending.reviewerUid == ctx.reviewer.principal.uid

    assert {:ok, ^pending} = Approvals.request(ctx.page.id, ctx.owner, ctx.owner, ctx.input)

    assert {:error, :approval_conflict} =
             Approvals.request(ctx.page.id, ctx.owner, ctx.owner, %{
               ctx.input
               | "details" => "Other"
             })

    assert {:ok, ^pending} = Approvals.get(ctx.page.id, ctx.reviewer, pending.id)
    assert {:error, :not_found} = Approvals.get(ctx.page.id, ctx.other, pending.id)

    decision = %{"id" => pending.id, "decision" => "approved", "note" => "Evidence verified."}
    assert {:error, :forbidden} = Approvals.decide(ctx.page.id, ctx.owner, decision)
    assert {:error, :forbidden} = Approvals.decide(ctx.page.id, ctx.other, decision)

    assert {:ok, approved} = Approvals.decide(ctx.page.id, ctx.reviewer, decision)
    assert %{status: "approved", note: "Evidence verified."} = approved
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(approved.decidedAt)
    assert approved.requestedAt == pending.requestedAt
    assert {:ok, ^approved} = Approvals.decide(ctx.page.id, ctx.reviewer, decision)
    assert {:ok, ^approved} = Approvals.get(ctx.page.id, ctx.owner, pending.id)
    assert {:ok, ^approved} = Approvals.request(ctx.page.id, ctx.owner, ctx.owner, ctx.input)

    assert {:error, :approval_conflict} =
             Approvals.decide(ctx.page.id, ctx.reviewer, %{decision | "decision" => "rejected"})

    assert {:error, :approval_conflict} =
             Approvals.decide(ctx.page.id, ctx.reviewer, %{decision | "note" => "Changed note"})
  end

  test "review inbox is Page-scoped, limited to its participants and orders open work first",
       ctx do
    assert {:ok, pending} = Approvals.request(ctx.page.id, ctx.owner, ctx.owner, ctx.input)

    assert {:ok, newer} =
             Approvals.request(ctx.page.id, ctx.owner, ctx.other, %{
               ctx.input
               | "requestKey" => "request-18"
             })

    assert newer.requesterUid == ctx.other.principal.uid

    assert {:ok, rejected} =
             Approvals.decide(ctx.page.id, ctx.reviewer, %{
               "id" => newer.id,
               "decision" => "rejected"
             })

    assert %{status: "rejected", note: nil} = rejected
    assert {:ok, %{approvals: [^pending, ^rejected]}} = Approvals.list(ctx.page.id, ctx.reviewer)
    assert {:ok, %{approvals: [^pending]}} = Approvals.list(ctx.page.id, ctx.owner)
    assert {:ok, %{approvals: [^rejected]}} = Approvals.list(ctx.page.id, ctx.other)

    {:ok, other_page} =
      Pages.create(ctx.owner, %{type: :applet, private_owner_uid: ctx.owner.principal.uid})

    assert {:error, :not_found} = Approvals.get(other_page.id, ctx.owner, pending.id)
    assert {:ok, %{approvals: []}} = Approvals.list(other_page.id, ctx.owner)

    assert {:ok, another} =
             Approvals.request(other_page.id, ctx.owner, ctx.owner, %{
               ctx.input
               | "reviewerUid" => ctx.owner.principal.uid
             })

    refute another.id == pending.id
  end

  test "invalid input, insufficient submission authority and lost reviewer access are rejected",
       ctx do
    assert {:error, :invalid_request} =
             Approvals.request(ctx.page.id, ctx.owner, ctx.owner, %{ctx.input | "summary" => "  "})

    assert {:error, :forbidden} =
             Approvals.request(ctx.page.id, ctx.other, ctx.other, ctx.input)

    assert {:ok, pending} = Approvals.request(ctx.page.id, ctx.owner, ctx.owner, ctx.input)

    {:ok, _} = PagesFixtures.set_sharing(ctx.owner.principal.uid, ctx.page.id, %{grants: []})

    assert {:error, :forbidden} = Approvals.get(ctx.page.id, ctx.reviewer, pending.id)

    assert {:error, :forbidden} =
             Approvals.decide(ctx.page.id, ctx.reviewer, %{
               "id" => pending.id,
               "decision" => "approved"
             })

    assert {:ok, ^pending} = Approvals.get(ctx.page.id, ctx.owner, pending.id)

    assert {:error, :forbidden} =
             Approvals.request(ctx.page.id, ctx.owner, ctx.owner, %{
               ctx.input
               | "requestKey" => "request-19"
             })
  end
end
