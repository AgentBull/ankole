defmodule Ankole.SignalsGateway.IMGroupProjectionTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AppConfigure
  alias Ankole.AuthZ.{ExternalBinding, Membership}
  alias Ankole.Plugins.SlackAdapter.{Channels, Config}

  alias Ankole.SignalsGateway.{
    AdapterContext,
    Binding,
    BindingMembership,
    Channel,
    IMGroupMembers,
    IMGroupProjection
  }

  setup do
    allow_cache_database_access()
    %{principal: agent} = agent_fixture()
    context = AdapterContext.new(agent_uid: agent.uid, binding_name: "group", adapter: "slack")
    %{agent: agent, context: context}
  end

  test "one group owns the external binding, channel and participant projection", %{
    context: context
  } do
    assert {:ok, group} =
             IMGroupProjection.ensure_group("slack-main", "C1", %{}, context, opts(:replace))

    assert group.name == "slack-main:im_group:c1"
    assert group.display_name == "Slack Channel C1"
    assert BindingMembership.joined?(group.metadata, context)

    assert {:ok, updated} =
             IMGroupProjection.ensure_group(
               "slack-main",
               "C1",
               %{"name" => "Renamed"},
               context,
               opts(:replace)
             )

    assert updated.id == group.id
    assert updated.display_name == "Renamed"
    assert Repo.get_by!(Channel, id: "slack:C1").principal_group_id == group.id

    assert Repo.one!(
             from binding in ExternalBinding,
               where: binding.provider == "slack-main" and binding.external_id == "C1"
           ).metadata == %{"provider" => "slack-main", "externalID" => "C1"}
  end

  test "keep_existing retains another namespace and emits the conflict warning", %{
    context: context
  } do
    assert {:ok, original} =
             IMGroupProjection.ensure_group("first", "C1", %{}, context, opts(:replace))

    log =
      capture_log([metadata: [:event]], fn ->
        assert {:ok, other} =
                 IMGroupProjection.ensure_group(
                   "second",
                   "C1",
                   %{},
                   context,
                   opts(:keep_existing)
                 )

        refute other.id == original.id
        assert Repo.get_by!(Channel, id: "slack:C1").principal_group_id == original.id
      end)

    assert log =~ "signals_gateway.im_group.channel_namespace_conflict"
  end

  test "replace changes the channel group while preserving both external bindings", %{
    context: context
  } do
    assert {:ok, first} =
             IMGroupProjection.ensure_group("first", "C1", %{}, context, opts(:replace))

    assert {:ok, second} =
             IMGroupProjection.ensure_group("second", "C1", %{}, context, opts(:replace))

    refute first.id == second.id
    assert Repo.get_by!(Channel, id: "slack:C1").principal_group_id == second.id
    assert {:ok, retained} = IMGroupProjection.get_group("first", "C1")
    assert retained.id == first.id
  end

  test "one leaving binding removes only its Agent; all-left clears every member", %{
    context: first
  } do
    %{principal: second_agent} = agent_fixture()
    %{principal: human} = human_fixture()
    second = %{first | agent_uid: second_agent.uid, binding_name: "second"}

    assert {:ok, group} =
             IMGroupProjection.ensure_group("slack-main", "C1", %{}, first, opts(:replace))

    assert {:ok, _} =
             IMGroupProjection.ensure_group("slack-main", "C1", %{}, second, opts(:replace))

    assert {:ok, _} = IMGroupMembers.replace_members(group.id, [human.uid])

    assert {:ok, %{status: :participant_marked_left}} =
             IMGroupProjection.mark_left("slack-main", "C1", first)

    refute Repo.get_by(Membership, group_id: group.id, principal_uid: first.agent_uid)
    assert Repo.get_by(Membership, group_id: group.id, principal_uid: second.agent_uid)
    assert Repo.get_by(Membership, group_id: group.id, principal_uid: human.uid)

    assert {:ok, %{status: :all_left_members_cleared}} =
             IMGroupProjection.mark_all_left("slack-main", "C1")

    refute Repo.exists?(from membership in Membership, where: membership.group_id == ^group.id)
    assert {:ok, _} = IMGroupProjection.get_group("slack-main", "C1")
    assert Repo.get_by!(Channel, id: "slack:C1").principal_group_id == group.id
  end

  test "a full snapshot marks absent groups left for its own binding", %{context: context} do
    assert {:ok, _} =
             IMGroupProjection.ensure_group("slack-main", "C1", %{}, context, opts(:replace))

    assert {:ok, 0} = IMGroupProjection.mark_missing_left("slack-main", ["C1"], context)
    assert {:ok, 1} = IMGroupProjection.mark_missing_left("slack-main", [], context)
    assert {:ok, group} = IMGroupProjection.get_group("slack-main", "C1")
    refute BindingMembership.joined?(group.metadata, context)
  end

  test "Slack member fetch releases the projection transaction and connection", %{agent: agent} do
    Req.Test.set_req_test_to_shared()
    previous = Application.fetch_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, Config, value)
        :error -> Application.delete_env(:ankole, Config)
      end
    end)

    binding = binding_fixture(agent.uid, "slack-projection", :ignore, adapter: "slack")
    key = Config.binding_config_key(agent.uid, binding.name)

    assert {:ok, _} =
             AppConfigure.put_global_by_key(key, %{
               "botToken" => "xoxb-projection",
               "appToken" => "xapp-projection"
             })

    binding |> Ecto.Changeset.change(config_ref: "app-config://#{key}") |> Repo.update!()
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      refute Repo.in_transaction?()

      case conn.request_path do
        "/api/conversations.info" ->
          Req.Test.json(conn, %{"ok" => true, "channel" => %{"id" => "C1", "name" => "Room"}})

        "/api/users.list" ->
          Req.Test.json(conn, %{"ok" => true, "members" => []})

        "/api/conversations.members" ->
          send(parent, {:members_waiting, self()})

          receive do
            :release_members -> Req.Test.json(conn, %{"ok" => true, "members" => []})
          after
            5_000 -> flunk("member fetch was not released")
          end
      end
    end)

    tenant_id = Repo.tenant_id!()

    sync =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn ->
          Channels.refresh_channel(agent.uid, binding.name, "C1")
        end)
      end)

    assert_receive {:members_waiting, fetcher}, 5_000

    write =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn ->
          binding |> Ecto.Changeset.change(enabled: false) |> Repo.update()
        end)
      end)

    assert {:ok, %Binding{enabled: false}} = Task.await(write, 1_000)
    send(fetcher, :release_members)
    assert {:ok, %{synced_members: 0}} = Task.await(sync, 5_000)
  end

  defp opts(policy) do
    [
      default_display_name: "Slack Channel C1",
      binding_metadata: %{"provider" => "slack-main", "externalID" => "C1"},
      channel: %{
        on_conflict: policy,
        fact: %{
          signal_channel_id: "slack:C1",
          channel_name: nil,
          channel_visibility: nil,
          channel_kind: :im_group,
          reply_mode: :entry,
          channel_metadata: %{},
          channel_raw_payload: %{}
        }
      }
    ]
  end
end
