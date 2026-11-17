defmodule Ankole.SiteConsole.AggregatesTest do
  use Ankole.DataCase, async: false

  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.{AutomationJobs, Repo, Schedule, Signals}
  alias Ankole.AutomationJobs.JobSources
  alias Ankole.Pod.Pages
  alias Ankole.SiteConsole.Aggregates

  test "schedules excludes deleted/detached rows and paginates identical (tenant, agent_uid, name) across rooms" do
    owner = human_fixture()

    %{agent: agent} =
      agent_fixture(%{uid: "sched_agg_agent", owner_principal_uid: owner.principal.uid})

    create_room_schedule = fn room_suffix, name ->
      original =
        Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid,
          binding_name: "bot-#{room_suffix}"
        )

      source_id = Ecto.UUID.generate()

      {:ok, source} =
        Repo.transact_top_level(fn ->
          Signals.accept_in_tx(%{
            source: "test://agg-sched-#{room_suffix}",
            id: source_id,
            type: "conversation.message.addressed",
            time: DateTime.utc_now(),
            sender: owner.principal.uid,
            target: %{agent_uid: agent.uid, session_id: "work:#{source_id}"},
            data: %{"text" => "Run digest"},
            reply_route: %{
              binding_name: original.reply_binding_name,
              conversation_id: original.conversation_id,
              provider_message_id: original.provider_message_id
            }
          })
        end)

      {:ok, %{cron_schedule: cron}} =
        Schedule.create_cron_schedule(
          %{
            "agent_uid" => source.agent_uid,
            "owner_session_id" => source.session_id,
            "binding_name" => source.reply_binding_name,
            "name" => name,
            "idempotency_key" => source.id,
            "payload" => %{"task" => "Daily digest"},
            "delivery" => %{
              "targets" => [
                %{
                  "binding_name" => source.reply_binding_name,
                  "conversation_id" => source.conversation_id
                }
              ]
            },
            "schedule" => %{
              "kind" => "every",
              "every_ms" => 86_400_000,
              "anchor_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
            }
          },
          created_by: %{"kind" => "turn", "signal_id" => source.id}
        )

      cron
    end

    cron_room_1 = create_room_schedule.("r1", "same-digest")
    cron_room_2 = create_room_schedule.("r2", "same-digest")
    cron_room_3 = create_room_schedule.("r3", "same-digest")
    deleted_cron = create_room_schedule.("deleted", "same-digest")

    assert {:ok, %{status: :deleted}} = Schedule.remove_cron_schedule(deleted_cron.id)

    owner_actor = actor_fixture(owner.principal.uid)
    {:ok, applet_page} = Pages.create(owner_actor, %{type: "applet"})

    publish_applet_fixture(
      %{actor: owner_actor, page: applet_page},
      """
      export default {
        actions: {
          work: { idempotent: true, concurrency: 'serial_fifo', handler: ctx => ctx.signal.data }
        }
      }
      """
    )

    {:ok, applet_job} =
      AutomationJobs.create_applet_job(owner_actor, applet_page.id, "work", %{
        authorization_kind: "human"
      })

    {:ok, nil_agent_cron} =
      JobSources.schedules(owner_actor, applet_page.id, applet_job.id, :put, %{
        name: "sched_agg_agent_applet_job",
        schedule: %{kind: "cron", expression: "*/10 * * * *"},
        timezone: "Asia/Shanghai",
        payload: %{}
      })

    assert is_nil(nil_agent_cron.agent_uid)

    # Paginate 1 item at a time across identical (tenant_slug, agent_uid, name)
    {:ok, p1} = Ankole.Ash.run_action(Aggregates, :schedules, %{limit: 1, q: "sched_agg_agent"})
    assert [i1] = p1.items
    assert is_binary(p1.next_cursor)

    {:ok, p2} =
      Ankole.Ash.run_action(Aggregates, :schedules, %{
        limit: 1,
        q: "sched_agg_agent",
        cursor: p1.next_cursor
      })

    assert [i2] = p2.items
    assert is_binary(p2.next_cursor)

    {:ok, p3} =
      Ankole.Ash.run_action(Aggregates, :schedules, %{
        limit: 5,
        q: "sched_agg_agent",
        cursor: p2.next_cursor
      })

    assert [i3] = p3.items
    assert is_nil(p3.next_cursor)

    returned_ids = [i1.id, i2.id, i3.id]
    assert Enum.sort(returned_ids) == Enum.sort([cron_room_1.id, cron_room_2.id, cron_room_3.id])
    refute deleted_cron.id in returned_ids
    refute nil_agent_cron.id in returned_ids

    {:ok, all_page} = Ankole.Ash.run_action(Aggregates, :schedules, %{limit: 50})
    all_ids = Enum.map(all_page.items, & &1.id)
    refute deleted_cron.id in all_ids
    refute nil_agent_cron.id in all_ids
  end
end
