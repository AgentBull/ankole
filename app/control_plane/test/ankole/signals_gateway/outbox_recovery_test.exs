defmodule Ankole.SignalsGatewayOutboxRecoveryTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  @base_time ~U[2026-06-23 08:00:00.000000Z]

  describe "outbox recovery retry and cleanup" do
    test "in-flight outbox recovers by reconciliation or marks unknown when unprovable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, unknown_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-unknown",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 provider_entry_id: "maybe-provider-id"
               })

      {:ok, _sending} =
        unknown_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-unknown",
                 %{capabilities: [:post_entry]},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert unknown.status == :unknown_after_send

      refute Repo.get_by(SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "maybe-provider-id"
             )

      assert {:ok, reconcile_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed",
                 provider_entry_id: "confirmed-provider-id"
               })

      {:ok, _sending} =
        reconcile_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, recovered} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-reconcile",
                 %{
                   capabilities: [:post_entry, :outbound_reconciliation],
                   reconcile: fn _outbox ->
                     {:ok, %{provider_entry_id: "confirmed-provider-id"}}
                   end
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert recovered.status == :succeeded

      assert Repo.get_by!(
               SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "confirmed-provider-id"
             ).text == "confirmed"
    end

    test "invalid reconcile result marks in-flight outbox unknown without crashing" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "started-invalid-reconcile",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "maybe sent",
                 provider_entry_id: "maybe-sent-provider-id"
               })

      {:ok, _sending} =
        seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, unknown} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "started-invalid-reconcile",
                 %{
                   capabilities: [:post_entry, :outbound_reconciliation],
                   reconcile: fn _outbox -> :ok end
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert unknown.status == :unknown_after_send
      assert unknown.last_error["reason"] == "reconciliation adapter error"
      assert unknown.last_error["error"]["items"] |> hd() == "invalid_adapter_result"
    end

    test "due outbox dispatch picks up stale in-flight sends for reconciliation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, stale_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "stale-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "confirmed by reconcile",
                 provider_entry_id: "stale-provider-id"
               })

      due_now = DateTime.add(@base_time, 61, :second)

      {:ok, _sending} =
        stale_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: @base_time
        })
        |> Repo.update()

      assert {:ok, fresh_seed} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "fresh-sending",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "still in flight",
                 provider_entry_id: "fresh-provider-id"
               })

      {:ok, _fresh} =
        fresh_seed
        |> OutboxEntry.changeset(%{
          status: :sending,
          platform_send_started_at: DateTime.add(due_now, -30, :second)
        })
        |> Repo.update()

      assert [%OutboxEntry{outbound_key: "stale-sending"}] =
               SignalsGateway.list_due_outbox(due_now, 10)

      assert [{:ok, %OutboxEntry{status: :succeeded}}] =
               SignalsGateway.dispatch_due_outbox(
                 fn %OutboxEntry{binding_name: "bot"} ->
                   {:ok,
                    %{
                      capabilities: [:post_entry, :outbound_reconciliation],
                      reconcile: fn _outbox ->
                        {:ok, %{provider_entry_id: "stale-provider-id"}}
                      end
                    }}
                 end,
                 now: due_now,
                 limit: 10
               )

      assert Repo.get_by!(
               SignalEntry,
               signal_channel_id: "lark:chat:group-a",
               provider_entry_id: "stale-provider-id"
             ).text == "confirmed by reconcile"
    end

    test "due outbox dispatch honors retry backoff through a code resolver" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{status: :accepted}} =
               SignalsGateway.emit_entry(agent.uid, "bot", group_entry(%{explicit: true}),
                 now: @base_time
               )

      assert {:ok, _created} =
               SignalsGateway.commit_outbox(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: "post-retry",
                 operation: :post,
                 signal_channel_id: "lark:chat:group-a",
                 fallback_visible_text: "retry me"
               })

      assert {:ok, failed} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:error, :rate_limited} end},
                 now: @base_time
               )

      assert failed.status == :failed

      assert {:error, :outbox_not_due} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 "post-retry",
                 %{capabilities: [:post_entry], send: fn _outbox -> {:ok, %{}} end},
                 now: DateTime.add(@base_time, 1, :second)
               )

      due_now = DateTime.add(failed.next_attempt_at, 1, :microsecond)

      assert [%OutboxEntry{outbound_key: "post-retry"}] =
               SignalsGateway.list_due_outbox(due_now, 10)

      assert [{:ok, %OutboxEntry{status: :succeeded}}] =
               SignalsGateway.dispatch_due_outbox(
                 fn %OutboxEntry{binding_name: "bot"} ->
                   {:ok,
                    %{
                      capabilities: [:post_entry],
                      send: fn _outbox -> {:ok, %{provider_entry_id: "retry-provider-id"}} end
                    }}
                 end,
                 now: due_now,
                 limit: 10
               )
    end

    test "TTL cleanup is an Oban default-queue worker over SignalsGateway TTL tables" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, _} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-expiring"}),
                 now: @base_time
               )

      assert %Oban.Job{queue: "default"} =
               Ankole.SignalsGateway.Jobs.CleanupExpiredState.new(%{})
               |> Ecto.Changeset.apply_changes()

      counts =
        SignalsGateway.cleanup_expired_state(DateTime.add(@base_time, 2 * 24 * 60 * 60, :second))

      assert counts.tombstones == 1
      assert Repo.aggregate(InputTombstone, :count) == 0
    end
  end
end
