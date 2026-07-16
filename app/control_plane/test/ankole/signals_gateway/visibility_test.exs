defmodule Ankole.SignalsGateway.VisibilityTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures, only: [binding_fixture: 3, binding_fixture: 4]

  alias Ankole.AuthZ.Group
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.BindingMembership
  alias Ankole.SignalsGateway.Channel

  test "visible_channels unions joined bindings and observed private channels" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "primary", :ignore)
    now = DateTime.utc_now(:microsecond)

    joined = group_channel!(agent.uid, "primary", "joined", now)
    unrelated = group_channel!(other_agent.uid, "other", "joined", now)
    dm = channel!("visible-dm", :im_dm, now)

    assert {:ok, _event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "primary",
               session_id: "visibility-session",
               source_event_id: "visibility-event",
               signal_channel_id: dm.id,
               source_entry_id: "visibility-message",
               type: "im.message.addressed",
               available_at: now,
               payload: %{}
             })

    assert SignalsGateway.visible_channels(agent.uid)
           |> Enum.map(& &1.id)
           |> MapSet.new() == MapSet.new([joined.id, dm.id])

    refute unrelated.id in Enum.map(SignalsGateway.visible_channels(agent.uid), & &1.id)
  end

  test "an observed IM group stops being visible when the provider marks the agent left" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "primary", :ignore)
    now = DateTime.utc_now(:microsecond)
    group = group_channel!(agent.uid, "primary", "joined", now)

    observe_channel!(agent.uid, "primary", group.id, now)
    assert group.id in visible_channel_ids(agent.uid)

    put_participant_state!(group, agent.uid, "primary", "left")
    refute group.id in visible_channel_ids(agent.uid)
  end

  test "an observed IM group stops being visible when its provider binding is disabled" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "primary", :ignore)
    now = DateTime.utc_now(:microsecond)
    group = group_channel!(agent.uid, "primary", "joined", now)

    observe_channel!(agent.uid, "primary", group.id, now)
    assert group.id in visible_channel_ids(agent.uid)

    assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, "primary")
    refute group.id in visible_channel_ids(agent.uid)
  end

  test "historically observed DMs remain visible after their binding is disabled" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "primary", :ignore)
    now = DateTime.utc_now(:microsecond)
    dm = channel!("historical-dm", :im_dm, now)

    observe_channel!(agent.uid, "primary", dm.id, now)
    assert {:ok, _binding} = SignalsGateway.disable_binding(agent.uid, "primary")

    assert dm.id in visible_channel_ids(agent.uid)
  end

  test "host membership visibility does not require a provider-specific query branch" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "teams-main", :ignore, adapter: "teams")
    now = DateTime.utc_now(:microsecond)

    teams_group =
      group_channel!(agent.uid, "teams-main", "joined", now, provider: "teams")

    assert teams_group.id in visible_channel_ids(agent.uid)
  end

  defp group_channel!(agent_uid, binding_name, state, now, opts \\ []) do
    id = "visibility:#{Ecto.UUID.generate()}"
    provider = Keyword.get(opts, :provider, "lark")
    context = adapter_context(agent_uid, binding_name, provider)
    state = if state == "joined", do: :joined, else: :left

    group =
      %Group{}
      |> Group.changeset(%{
        name: "#{id}:group",
        display_name: id,
        domain: :im_group,
        metadata: BindingMembership.project(%{}, context, state, now)
      })
      |> Repo.insert!()

    channel!(id, :im_group, now, principal_group_id: group.id)
  end

  defp observe_channel!(agent_uid, binding_name, channel_id, now) do
    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: binding_name,
        session_id: "visibility-session-#{Ecto.UUID.generate()}",
        source_event_id: "visibility-event-#{Ecto.UUID.generate()}",
        signal_channel_id: channel_id,
        source_entry_id: "visibility-message-#{Ecto.UUID.generate()}",
        type: "im.message.addressed",
        available_at: now,
        payload: %{}
      })

    event
  end

  defp put_participant_state!(channel, agent_uid, binding_name, state) do
    group = Repo.get!(Group, channel.principal_group_id)
    state = if state == "joined", do: :joined, else: :left

    metadata =
      BindingMembership.project(
        group.metadata,
        adapter_context(agent_uid, binding_name, "lark"),
        state
      )

    group
    |> Group.changeset(%{metadata: metadata})
    |> Repo.update!()
  end

  defp visible_channel_ids(principal_uid) do
    principal_uid
    |> SignalsGateway.visible_channels()
    |> Enum.map(& &1.id)
  end

  defp adapter_context(agent_uid, binding_name, adapter) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: binding_name,
      adapter: adapter,
      user_name: adapter
    )
  end

  defp channel!(prefix, kind, now, attrs \\ []) do
    %Channel{}
    |> Channel.changeset(%{
      id: "#{prefix}:#{Ecto.UUID.generate()}",
      kind: kind,
      reply_mode: :entry,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now,
      principal_group_id: Keyword.get(attrs, :principal_group_id)
    })
    |> Repo.insert!()
  end
end
