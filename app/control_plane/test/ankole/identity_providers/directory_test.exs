defmodule Ankole.IdentityProviders.DirectoryTest do
  use Ankole.DataCase, async: false

  alias Ankole.AuthZ.Membership
  alias Ankole.IdentityProviders.Directory
  alias Ankole.Plugins.SlackAdapter.IdentityProvider
  alias Ankole.Principals

  @provider "slack-sync-loop"

  test "counts imported users, skips excluded users, and writes group memberships" do
    assert {:ok, group} =
             Directory.ensure_group(@provider, %Directory.Group{
               external_id: "S1",
               kind: "usergroup",
               display_name: "Engineering"
             })

    users = [
      {:ok, %{"id" => "U1", "name" => "Ada"}},
      {:ok, %{"id" => "BOT", "is_bot" => true}},
      {:ok, %{"id" => "U2", "name" => "Grace"}}
    ]

    assert {:ok, 2} =
             Directory.sync_users(@provider, users, fn user, index ->
               if user["is_bot"] do
                 :skip
               else
                 IdentityProvider.upsert_user(@provider, user,
                   directory_group_index: index,
                   group_external_ids: ["S1"]
                 )
               end
             end)

    for id <- ["U1", "U2"] do
      assert {:ok, uid} = Principals.resolve_platform_subject_uid(@provider, id)
      assert Repo.get_by(Membership, principal_uid: uid, group_id: group.id)
    end

    assert {:error, :not_found} = Principals.resolve_platform_subject_uid(@provider, "BOT")
  end

  test "a page failure stops the lazy stream and retains earlier user writes" do
    users =
      observed_stream([{:ok, %{"id" => "U1"}}, {:error, :page_failed}, {:ok, %{"id" => "U2"}}])

    assert {:error, :page_failed} = Directory.sync_users(@provider, users, &import_user/2)
    assert_received {:enumerated, {:error, :page_failed}}
    refute_received {:enumerated, {:ok, %{"id" => "U2"}}}
    assert {:ok, _uid} = Principals.resolve_platform_subject_uid(@provider, "U1")
    assert {:error, :not_found} = Principals.resolve_platform_subject_uid(@provider, "U2")
  end

  test "a user write failure stops enumeration and retains earlier user writes" do
    users = observed_stream([{:ok, %{"id" => "U1"}}, {:ok, %{}}, {:ok, %{"id" => "U2"}}])

    assert {:error, :missing_user_id} = Directory.sync_users(@provider, users, &import_user/2)
    assert_received {:enumerated, {:ok, %{}}}
    refute_received {:enumerated, {:ok, %{"id" => "U2"}}}
    assert {:ok, _uid} = Principals.resolve_platform_subject_uid(@provider, "U1")
    assert {:error, :not_found} = Principals.resolve_platform_subject_uid(@provider, "U2")
  end

  defp import_user(user, index),
    do: IdentityProvider.upsert_user(@provider, user, directory_group_index: index)

  defp observed_stream(users) do
    Stream.map(users, fn item ->
      send(self(), {:enumerated, item})
      item
    end)
  end
end
