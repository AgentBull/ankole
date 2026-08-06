defmodule Ankole.SignalsGateway.ActorRuntime.ScheduledTurnTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.ActorRuntime.ScheduledTurn

  describe "consecutive identical cron replies" do
    test "counts the streak across digits, URLs, and whitespace variance" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取 07:05–07:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=111&code=230027)
      """)

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取 08:05–08:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=222&code=230027)
      """)

      fire_with_reply(agent.uid, session_id, "monitor", """
      ⚠️ 监控仍被飞书权限错误 **230027** 阻断，无法读取   09:05–09:20 的群消息。
      [查看本次排查信息](https://open.feishu.cn/search?log_id=333&code=230027)
      """)

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert ScheduledTurn.consecutive_identical_replies(input) == 3

      opts = ScheduledTurn.opts(input, [])
      assert opts[:request_context]["consecutive_identical_replies"] == 3
    end

    test "stops the streak at the first different reply" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "工作簿已更新，本轮读取 12 条消息。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert ScheduledTurn.consecutive_identical_replies(input) == 2
    end

    test "one prior reply is not a streak and adds no context field" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert ScheduledTurn.consecutive_identical_replies(input) == 1

      opts = ScheduledTurn.opts(input, [])
      refute Map.has_key?(opts[:request_context], "consecutive_identical_replies")
    end

    test "a silent previous fire breaks the streak" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      cron_fire_event(agent.uid, session_id, "monitor")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert ScheduledTurn.consecutive_identical_replies(input) == 0
    end

    test "other schedules and other sessions stay out of the streak" do
      %{agent: agent, session_id: session_id} = cron_session()

      fire_with_reply(agent.uid, session_id, "other-schedule", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, "other-session", "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")
      fire_with_reply(agent.uid, session_id, "monitor", "⚠️ 监控失败：权限错误 230027。")

      input = cron_fire_event(agent.uid, session_id, "monitor")

      assert ScheduledTurn.consecutive_identical_replies(input) == 2
    end

    test "a checkback wakeup never reports a streak" do
      %{agent: agent, session_id: session_id} = cron_session()

      {:ok, input} =
        SignalsGateway.append_actor_event(%{
          agent_uid: agent.uid,
          binding_name: "control-plane:test",
          session_id: session_id,
          source_event_id: "checkback-#{System.unique_integer([:positive])}",
          type: "check_back_later.wakeup",
          available_at: @base_time,
          payload: %{"data" => %{"wake_payload" => %{"quiet_success" => false}}}
        })

      assert ScheduledTurn.consecutive_identical_replies(input) == 0
    end
  end

  defp cron_session do
    %{principal: agent} = agent_fixture()
    %{agent: agent, session_id: "session-#{System.unique_integer([:positive])}"}
  end

  defp cron_fire_event(agent_uid, session_id, schedule_name) do
    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "control-plane:test",
        session_id: session_id,
        source_event_id: "cron-fire-#{System.unique_integer([:positive])}",
        type: "cron.fire",
        available_at: @base_time,
        payload: %{
          "data" => %{
            "schedule_kind" => "cron",
            "wake_payload" => %{"cron_schedule_name" => schedule_name}
          }
        }
      })

    event
  end

  defp fire_with_reply(agent_uid, session_id, schedule_name, reply_text) do
    event = cron_fire_event(agent_uid, session_id, schedule_name)

    Repo.insert!(%OutboxEntry{
      agent_uid: agent_uid,
      binding_name: "control-plane:test",
      outbound_key: "reply-#{System.unique_integer([:positive])}",
      operation: :reply,
      status: :succeeded,
      source_actor_event_id: event.id,
      fallback_visible_text: reply_text,
      idempotency_key: "idem-#{System.unique_integer([:positive])}"
    })

    event
  end
end
