defmodule Ankole.Principals.ColleagueChatMigrationTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  test "migration backfills default all_humans chat only for ungranted AI colleagues and reverses cleanly" do
    path =
      Path.expand(
        "../../../priv/repo/migrations/20261105010000_grant_all_humans_colleague_chat.exs",
        __DIR__
      )

    unless Code.ensure_loaded?(Ankole.Repo.Migrations.GrantAllHumansColleagueChat),
      do: Code.require_file(path)

    member = human_fixture(%{display_name: "Member"}).principal
    specialist_owner = human_fixture(%{display_name: "Specialist Owner"}).principal
    guest = human_fixture(%{display_name: "Guest", membership: :guest}).principal
    worker_provider_fixture(%{is_default: true})

    legacy_colleague =
      agent_fixture(%{
        uid: "legacy_colleague",
        display_name: "Legacy Colleague",
        owner_principal_uid: specialist_owner.uid
      }).principal

    restricted_colleague =
      agent_fixture(%{
        uid: "restricted_colleague",
        display_name: "Restricted Colleague",
        owner_principal_uid: specialist_owner.uid
      }).principal

    assert {:ok, %{principal: assistant}} =
             Ankole.Principals.ensure_personal_assistant(specialist_owner.uid)

    # Simulate legacy production rows created before `create_agent_in_tx/1`
    # seeded `all_humans` `"chat"` on `ai_colleague`s, plus one colleague whose
    # `"chat"` grant an operator customized to a single member.
    :ok = Ankole.ConversationsFixtures.revoke_default_chat(legacy_colleague.uid)
    :ok = Ankole.ConversationsFixtures.revoke_default_chat(restricted_colleague.uid)
    Ankole.ConversationsFixtures.grant_chat(specialist_owner.uid, restricted_colleague.uid)

    member_actor = actor_fixture(member)
    guest_actor = actor_fixture(guest)

    assert Ankole.Conversations.agents(member_actor) == []

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_105_010_000,
      Ankole.Repo.Migrations.GrantAllHumansColleagueChat,
      :forward,
      :up,
      :up,
      log: false
    )

    # Re-running backfill is idempotent.
    apply(Ankole.Repo.Migrations.GrantAllHumansColleagueChat, :backfill!, [Repo])

    assert Enum.map(Ankole.Conversations.agents(member_actor), & &1.uid) == [legacy_colleague.uid]
    assert Ankole.Conversations.agents(guest_actor) == []

    assert {:error, {:forbidden, "chat"}} =
             Ankole.AuthZ.authorize(member.uid, "agent:#{restricted_colleague.uid}", "chat")

    assert :ok =
             Ankole.AuthZ.authorize(
               specialist_owner.uid,
               "agent:#{restricted_colleague.uid}",
               "chat"
             )

    assert {:error, {:forbidden, "chat"}} =
             Ankole.AuthZ.authorize(member.uid, "agent:#{assistant.uid}", "chat")

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_105_010_000,
      Ankole.Repo.Migrations.GrantAllHumansColleagueChat,
      :forward,
      :down,
      :down,
      log: false
    )

    assert Ankole.Conversations.agents(member_actor) == []

    assert :ok =
             Ankole.AuthZ.authorize(
               specialist_owner.uid,
               "agent:#{restricted_colleague.uid}",
               "chat"
             )
  end
end
