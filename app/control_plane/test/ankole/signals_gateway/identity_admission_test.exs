defmodule Ankole.SignalsGateway.IdentityAdmissionTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequest
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxEntry

  defp dm_entry(author, overrides \\ %{}) do
    Map.merge(
      %{
        source_event_id: "evt-#{System.unique_integer([:positive])}",
        signal_channel_id: "lark:chat:admission",
        source_entry_id: "msg-#{System.unique_integer([:positive])}",
        channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"},
        text: "hello",
        author: author,
        provider_time: base_time()
      },
      overrides
    )
  end

  defp stranger_author(overrides \\ %{}) do
    Map.merge(
      %{
        id: "ou_stranger",
        platform_subject: "ou_stranger",
        display_name: "Stranger",
        metadata: %{"provider" => "lark-main"}
      },
      overrides
    )
  end

  test "manual review holds an unmatched sender: one pending row, one notice per message" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)

    assert {:ok, %{status: :held_unmapped_sender}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert {:ok, %{status: :held_unmapped_sender}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Entry, :count) == 0
    assert {:error, :not_found} = Principals.resolve_platform_subject("lark-main", "ou_stranger")

    assert [request] = Repo.all(MappingRequest)
    assert request.provider == "lark-main"
    assert request.external_id == "ou_stranger"
    assert request.display_name == "Stranger"

    notices = Repo.all(OutboxEntry)
    assert length(notices) == 2
    assert Enum.all?(notices, &(&1.operation == :reply))
    assert Enum.all?(notices, &(&1.fallback_visible_text =~ "Ankole Console"))
  end

  test "unaddressed group chatter from an unmatched sender is ignored entirely" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :record_only, unmatched_sender_policy: :manual_review)

    entry =
      dm_entry(stranger_author(), %{
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      })

    assert {:ok, %{status: :ignored_unmapped_sender}} =
             Ingress.emit_entry(agent.uid, "lark-adm", entry)

    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(MappingRequest, :count) == 0
    assert Repo.aggregate(OutboxEntry, :count) == 0
  end

  test "a sender that matches an existing principal by email is admitted and bound" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)
    %{principal: human, human_user: human_user} = human_fixture()

    author = stranger_author(%{email: human_user.email})

    assert {:ok, %{status: :accepted}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(author))

    assert {:ok, matched} = Principals.resolve_platform_subject("lark-main", "ou_stranger")
    assert matched.uid == human.uid
  end

  test "manual review admits a sender whose subject matches a global Principal UID" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :manual_review)
    %{principal: human} = human_fixture(%{uid: "ou_global_sender"})

    author =
      stranger_author(%{
        id: "ou_global_sender",
        platform_subject: "ou_global_sender",
        display_name: "Global Sender"
      })

    assert {:ok, %{status: :accepted}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(author))

    assert {:ok, matched} =
             Principals.resolve_platform_subject("lark-main", "ou_global_sender")

    assert matched.uid == human.uid
    assert Repo.aggregate(MappingRequest, :count) == 0
  end

  test "admitted senders accumulate in the binding's signal_source group" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :create_standalone)

    assert {:ok, %{status: :accepted}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    group_name = String.downcase("signal_source:#{agent.uid}:lark-adm")
    group = Repo.get_by!(Group, name: group_name)
    assert group.domain == :signal_source
    assert group.kind == :static

    assert {:ok, principal} = Principals.resolve_platform_subject("lark-main", "ou_stranger")

    assert Repo.get_by(Membership, group_id: group.id, principal_uid: principal.uid)

    # A second message from the same sender does not duplicate anything.
    assert {:ok, %{status: :accepted}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Membership, :count) >= 1
    assert [_group] = Repo.all(from group in Group, where: group.name == ^group_name)
  end

  test "a failed signal_source group write refuses the entry instead of admitting it" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "lark-adm", :ignore, unmatched_sender_policy: :create_standalone)

    # A same-named group in another domain makes the synced group write fail
    # with a domain mismatch, so the admission cannot complete.
    group_name = String.downcase("signal_source:#{agent.uid}:lark-adm")

    Repo.insert!(%Group{
      name: group_name,
      display_name: "collision",
      domain: :operator,
      kind: :static,
      metadata: %{}
    })

    assert {:error, {:signal_source_group, _reason}} =
             Ingress.emit_entry(agent.uid, "lark-adm", dm_entry(stranger_author()))

    assert Repo.aggregate(Entry, :count) == 0
  end
end
