defmodule Ankole.Brain.SourcesTest do
  use Ankole.DataCase, async: true
  import Ankole.BrainFixtures

  alias Ankole.Brain.Sources
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Repo

  test "OIDC learning skips an unscoped guest conversation until a scope exists while failing on broken scope" do
    guest = Ankole.PrincipalsFixtures.human_fixture(%{membership: :guest}).principal
    assert Ankole.Brain.Scope.principal(guest.uid) == nil
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(guest.uid, "guest-learning")

    {:ok, message} =
      Ankole.Ash.create(Ankole.AIGateway.Schemas.Message, :start, %{
        subject_uid: guest.uid,
        conversation_id: conversation.id,
        content: [%{"role" => "user", "content" => "Private guest conversation"}],
        metadata: %{"oidc_client_id" => "guest-client", "request_item_count" => 1}
      })

    {:ok, _} = Ankole.AIGateway.ResponseCommit.commit_complete(message, [])

    {:ok, source} =
      Sources.create(%{kind: "oidc_client", upstream_id: "guest-client", name: "Guest client"})

    assert Ankole.Brain.OIDCClientLearning.sweep() == 0

    assert {:ok, %{status: :learned, conversations: 0}} =
             Ankole.Brain.OIDCClientLearning.learn(source)

    assert Ankole.Brain.Scope.principal(guest.uid) == nil

    assert {:error, :not_found} =
             Ankole.Brain.Objects.get_by_slug("media/oidc-#{source.id}-#{conversation.id}")

    {:ok, _promoted} = Ankole.Principals.change_human_membership(guest.uid, :member)
    assert is_binary(Ankole.Brain.Scope.principal(guest.uid))
    assert Ankole.Brain.OIDCClientLearning.sweep() == 1

    member = Ankole.PrincipalsFixtures.human_fixture().principal

    Repo.delete_all(
      from(p in Ankole.Pod.Page,
        where: is_nil(p.parent_id) and p.private_owner_uid == ^member.uid
      )
    )

    assert Ankole.Brain.Scope.principal(member.uid) == nil

    {:ok, broken_conv} =
      Ankole.AIGatewayCase.ensure_conversation(member.uid, "missing-scope-learning")

    {:ok, broken_msg} =
      Ankole.Ash.create(Ankole.AIGateway.Schemas.Message, :start, %{
        subject_uid: member.uid,
        conversation_id: broken_conv.id,
        content: [%{"role" => "user", "content" => "Orphaned conversation"}],
        metadata: %{"oidc_client_id" => "broken-client", "request_item_count" => 1}
      })

    {:ok, _} = Ankole.AIGateway.ResponseCommit.commit_complete(broken_msg, [])

    {:ok, broken_source} =
      Sources.create(%{kind: "oidc_client", upstream_id: "broken-client", name: "Broken client"})

    assert {:error,
            {:conversation_learning_failed, [{broken_conv_id, :private_scope_unavailable}]}} =
             Ankole.Brain.OIDCClientLearning.learn(broken_source)

    assert broken_conv_id == broken_conv.id
  end

  test "recording an extraction watermark keeps Source list ordering" do
    assert {:ok, source} =
             Sources.create(%{kind: "conversation", upstream_id: "channel-1", name: "Channel"})

    boundary = {~U[2026-08-20 10:00:00.123456Z], 9}
    assert :ok = Sources.record_extraction_watermark(source, boundary)
    current = Repo.get!(Source, source.id)
    assert Sources.extraction_watermark(current) == 9
    assert current.updated_at == source.updated_at
  end

  test "a channel watermark is absent until a Source records its complete boundary" do
    assert Sources.conversation_extraction_watermark("channel-1") == nil

    assert {:ok, source} =
             Sources.create(%{kind: "conversation", upstream_id: "channel-1", name: "Channel"})

    assert Sources.conversation_extraction_watermark("channel-1") == nil
    boundary = {~U[2026-08-20 10:00:00.123456Z], 9}
    assert :ok = Sources.record_extraction_watermark(source, boundary)
    assert Sources.conversation_extraction_watermark("channel-1") == 9
  end

  test "strict creation rejects a duplicate while idempotent registration reuses it" do
    attrs = %{
      kind: "url",
      upstream_id: "https://example.com/source",
      name: "First name",
      default_source_node_id: source_node("world")
    }

    assert {:ok, first} = Sources.create(attrs)
    assert {:error, %Ash.Error.Invalid{errors: errors}} = Sources.create(attrs)

    assert [
             %Ash.Error.Changes.InvalidAttribute{field: :kind, message: "has already been taken"} =
               duplicate
           ] = errors

    assert duplicate.private_vars[:constraint] == "brain_sources_kind_upstream_key"
    assert duplicate.private_vars[:constraint_type] == :unique

    assert {:ok, reused} =
             attrs
             |> Map.put(:name, "Later name")
             |> Map.put(:default_source_node_id, Ankole.Ecto.UUIDv7.autogenerate())
             |> Sources.get_or_create()

    assert reused.id == first.id
    assert reused.name == first.name
    assert reused.default_source_node_id == first.default_source_node_id
  end

  test "archive is idempotent and keeps the first timestamp" do
    assert {:ok, source} =
             Sources.create(%{
               kind: "file",
               upstream_id: "/tmp/source.txt",
               name: "Source"
             })

    assert {:ok, first} = Ankole.Brain.archive_source(source.id)
    assert {:ok, second} = Ankole.Brain.archive_source(source.id)
    assert second.archived_at == first.archived_at
  end

  test "active locks and revision writes share the Source lifecycle" do
    assert {:ok, source} =
             Sources.get_or_create(%{
               kind: "library",
               upstream_id: "library",
               name: "Library"
             })

    assert {:ok, locked} =
             Repo.transact(fn -> Sources.lock_active(source) end)

    assert locked.id == source.id

    assert {:ok, revised} = Sources.record_revision(source, "revision-1")
    assert revised.upstream_revision == "revision-1"
    assert %DateTime{} = revised.last_sync_at

    assert {:ok, archived} = Ankole.Brain.archive_source(source.id)
    assert {:error, :source_archived} = Repo.transact(fn -> Sources.lock_active(archived) end)
  end
end
