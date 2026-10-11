defmodule Ankole.SignalsGateway.FinalReplyOutboxTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.Conversations.{Admission, Run}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  defmodule LateReplyPreview do
    use GenServer

    alias Ankole.SignalsGateway.Actors
    alias Ankole.SignalsGateway.AIReplyPreview

    def start_link({owner, event, preview_source_entry_id}) do
      GenServer.start_link(
        __MODULE__,
        {owner, event, preview_source_entry_id},
        name: AIReplyPreview.via_tuple(event)
      )
    end

    @impl true
    def init({owner, event, preview_source_entry_id}) do
      Ankole.Repo.put_tenant_id(event.tenant_id)

      {:ok,
       %{
         owner: owner,
         actor_event_id: event.id,
         preview_source_entry_id: preview_source_entry_id
       }}
    end

    @impl true
    def handle_cast({:for_event, id, :stop}, %{actor_event_id: id} = state) do
      send(state.owner, {:late_reply_preview_stop_requested, self()})
      {:noreply, state}
    end

    def handle_cast({:for_event, _other_id, :stop}, state), do: {:noreply, state}

    @impl true
    def handle_call({:owns_event, id}, _from, state),
      do: {:reply, state.actor_event_id == id, state}

    @impl true
    def handle_info(:settle, state) do
      :ok =
        Actors.record_reply_preview_source_entry(
          state.actor_event_id,
          state.preview_source_entry_id
        )

      {:stop, :normal, state}
    end
  end

  setup :use_mock_signal_provider_plugin

  describe "durable final reply outbox" do
    test "stopped preview keeps its acknowledged partial answer without duplicating the status" do
      %{event: event} = start_channel_reply_response_run()

      event =
        event
        |> ActorEvent.changeset(%{
          reply_preview_source_entry_id: "provider-stopped-preview",
          reply_preview_checkpoint: %{
            "presentation" => %{
              "schema_version" => 1,
              "state" => "working",
              "answer" => "已经确认的部分结果"
            }
          }
        })
        |> Repo.update!()

      assert {:ok, outbox} =
               Outbox.commit_stopped_turn_notice_outbox(event, "已停止。", "command.new")

      assert outbox.operation == :edit
      assert outbox.target_source_entry_id == "provider-stopped-preview"
      assert get_in(outbox.payload, ["reply_presentation", "state"]) == "stopped"

      assert get_in(outbox.payload, ["reply_presentation", "answer"]) ==
               "已经确认的部分结果"

      assert outbox.fallback_visible_text == "已停止。"
    end

    test "stopped preview without partial text stays metadata-only after late checkpoint refresh" do
      %{event: event} = start_channel_reply_response_run()

      assert [{preview_pid, _value}] =
               AIReplyPreview.lookup(event.id)

      preview_monitor = Process.monitor(preview_pid)
      assert :ok = AIReplyPreview.stop(event.id)
      assert_receive {:DOWN, ^preview_monitor, :process, ^preview_pid, :normal}

      event =
        ActorEvent
        |> Repo.get!(event.id)
        |> ActorEvent.changeset(%{
          reply_preview_source_entry_id: "provider-stopped-empty-preview",
          reply_preview_checkpoint: %{
            "presentation" => %{
              "schema_version" => 1,
              "state" => "working",
              "answer" => "",
              "plan" => %{
                "revision" => 1,
                "items" => [
                  %{"id" => "research", "content" => "研究请求", "status" => "in_progress"}
                ]
              }
            }
          }
        })
        |> Repo.update!()

      assert {:ok, outbox} =
               Outbox.commit_stopped_turn_notice_outbox(event, "任务已停止。", "command.new")

      assert get_in(outbox.payload, ["reply_presentation", "answer"]) == ""
      parent = self()

      adapter =
        outbox_adapter([:edit_entry], fn dispatched ->
          send(parent, {:stopped_empty_dispatched, dispatched})
          {:ok, %{raw_payload: %{}}}
        end)

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter
               )

      assert_receive {:stopped_empty_dispatched, dispatched}
      assert get_in(dispatched.payload, ["reply_presentation", "state"]) == "stopped"
      assert get_in(dispatched.payload, ["reply_presentation", "answer"]) == ""
      assert dispatched.fallback_visible_text == "任务已停止。"
    end

    test "turn completion without preview writes a durable reply outbox and mirrors after success" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()
      content = assistant_content("final answer")

      assert {:ok, completed} = StatefulResponses.commit_complete(message, content)
      assert completed.status == "complete"
      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :reply
      assert outbox.reply_to_source_entry_id == event.source_entry_id
      assert outbox.ai_message_id == message.id
      assert outbox.fallback_visible_text == "final answer"

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter(:reply_entry, "provider-final-reply")
               )

      assert %Entry{
               source_entry_id: "provider-final-reply",
               reply_to_source_entry_id: reply_to_source_entry_id,
               ai_message_id: ai_message_id
             } =
               Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
      assert reply_to_source_entry_id == event.source_entry_id
    end

    test "turn completion preserves a failed BackgroundAgentJob trigger in the durable presentation" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      event
      |> ActorEvent.changeset(%{
        type: "background_agent_job.failed",
        payload: %{
          "data" => %{
            "title" => "第二版 deep research",
            "result_summary" => "返回 JSON Schema 少声明了必填字段"
          }
        }
      })
      |> Repo.update!()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(
                 message,
                 assistant_content("我已修正配置并重新提交任务。")
               )

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")

      assert get_in(outbox.payload, ["reply_presentation", "answer"]) ==
               "我已修正配置并重新提交任务。"

      assert get_in(outbox.payload, ["reply_presentation", "trigger_context"]) == %{
               "kind" => "background_agent_job_failure",
               "title" => "第二版 deep research",
               "summary" => "返回 JSON Schema 少声明了必填字段"
             }
    end

    test "turn completion with preview writes a durable edit outbox and upserts final marker" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      event
      |> ActorEvent.changeset(%{reply_preview_source_entry_id: "provider-preview"})
      |> Repo.update!()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("edited final"))

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :edit
      assert outbox.target_source_entry_id == "provider-preview"
      assert outbox.ai_message_id == message.id

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter(:edit_entry, "ignored-for-edit")
               )

      assert %Entry{
               source_entry_id: "provider-preview",
               ai_message_id: ai_message_id,
               text: "edited final"
             } = Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
    end

    test "dispatch refreshes terminal metadata checkpointed while the preview stops" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      assert [{preview_pid, _value}] =
               AIReplyPreview.lookup(event.id)

      rich_adapter = %ReplyPreviewAdapter{
        surface_ids_fun: &MockReplyPreview.surface_ids/1,
        surface_open_fun: &MockReplyPreview.surface_open?/1,
        update_fun: fn _request -> {:ok, %{}} end,
        finalize_fun: fn _request -> {:ok, %{}} end
      }

      :sys.replace_state(preview_pid, fn state ->
        %{state | reply_preview_adapter: rich_adapter, silent_rich_pending: false}
      end)

      assert :ok =
               AIReplyPreview.presentation_event(event.id, %{
                 "kind" => "turn.phase",
                 "payload" => %{
                   "revision" => 1,
                   "state" => "working",
                   "label" => "正在理解请求"
                 }
               })

      assert :ok =
               AIReplyPreview.presentation_event(event.id, %{
                 "kind" => "plan.snapshot",
                 "payload" => %{
                   "operation_id" => "todo",
                   "revision" => 2,
                   "items" => [
                     %{
                       "id" => "verify",
                       "content" => "验证终态元数据",
                       "status" => "completed"
                     }
                   ]
                 }
               })

      assert :ok =
               AIReplyPreview.presentation_event(event.id, %{
                 "kind" => "tool.activity",
                 "payload" => %{
                   "operation_id" => "verify-card",
                   "revision" => 3,
                   "phase" => "completed",
                   "label" => "验证 CardKit 终态"
                 }
               })

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("final with plan"))

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      refute get_in(outbox.payload, ["reply_presentation", "plan"])
      assert get_in(outbox.payload, ["reply_presentation", "activities"]) == %{}

      stale_payload =
        put_in(
          outbox.payload,
          ["reply_presentation", "meta", "status"],
          "正在理解请求"
        )

      outbox =
        outbox
        |> OutboxEntry.changeset(%{payload: stale_payload})
        |> Repo.update!()

      parent = self()

      adapter =
        outbox_adapter([:reply_entry], fn dispatched ->
          send(parent, {:terminal_metadata_dispatched, dispatched})

          {:ok,
           %{
             created_source_entry_id: "provider-final-with-plan",
             raw_payload: %{"provider" => "test"}
           }}
        end)

      assert {:ok, %OutboxEntry{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter
               )

      assert_receive {:terminal_metadata_dispatched, dispatched}

      refute get_in(dispatched.payload, ["reply_presentation", "meta", "status"])

      assert get_in(dispatched.payload, ["reply_presentation", "plan", "items"]) == [
               %{
                 "id" => "verify",
                 "content" => "验证终态元数据",
                 "status" => "completed"
               }
             ]

      assert get_in(dispatched.payload, ["reply_presentation", "plan", "folded"])

      assert get_in(dispatched.payload, ["reply_presentation", "activities", "verify-card"]) ==
               %{
                 "operation_id" => "verify-card",
                 "revision" => 3,
                 "phase" => "completed",
                 "label" => "验证 CardKit 终态",
                 "consequential" => false
               }
    end

    test "quota notice waits for its preview and leaves a timed-out delivery retryable" do
      %{event: event} = start_channel_reply_response_run()
      preview_pid = replace_with_late_preview(event, "quota-preview")

      assert {:ok, outbox} =
               Repo.transact(fn repo ->
                 Outbox.commit_token_quota_exceeded_notice_outbox_in_tx(
                   repo,
                   event,
                   "quota notice"
                 )
               end)

      adapter = outbox_adapter([:reply_entry], fn _ -> flunk("preview has not settled") end)

      assert {:error, :reply_preview_settle_timeout} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter,
                 reply_preview_settle_timeout_ms: 0
               )

      assert_receive {:late_reply_preview_stop_requested, ^preview_pid}

      stored =
        Repo.get_by!(OutboxEntry,
          agent_uid: outbox.agent_uid,
          binding_name: outbox.binding_name,
          outbound_key: outbox.outbound_key
        )

      assert %{status: :created, attempt_count: 0, platform_send_started_at: nil} = stored
      assert Process.alive?(preview_pid)
      assert stored.payload["text"] == "quota notice"
      monitor = Process.monitor(preview_pid)
      send(preview_pid, :settle)
      assert_receive {:DOWN, ^monitor, :process, ^preview_pid, :normal}
    end

    test "quota notice adopts a preview entry recorded after its commit" do
      %{event: event} = start_channel_reply_response_run()
      preview_source_entry_id = "quota-preview-late"
      preview_pid = replace_with_late_preview(event, preview_source_entry_id)

      assert {:ok, outbox} =
               Repo.transact(fn repo ->
                 Outbox.commit_token_quota_exceeded_notice_outbox_in_tx(
                   repo,
                   event,
                   "quota notice"
                 )
               end)

      assert outbox.operation == :reply
      parent = self()

      adapter =
        outbox_adapter([:edit_entry], fn dispatched ->
          send(parent, {:quota_notice_dispatched, dispatched})
          {:ok, %{raw_payload: %{}}}
        end)

      dispatch =
        Task.async(
          Repo.bind_tenant(fn ->
            SignalsGateway.dispatch_outbox(
              outbox.agent_uid,
              outbox.binding_name,
              outbox.outbound_key,
              adapter,
              reply_preview_settle_timeout_ms: 1_000
            )
          end)
        )

      assert_receive {:late_reply_preview_stop_requested, ^preview_pid}
      refute_receive {:quota_notice_dispatched, _}, 100
      send(preview_pid, :settle)

      assert {:ok,
              %{
                status: :succeeded,
                operation: :edit,
                target_source_entry_id: ^preview_source_entry_id
              }} = Task.await(dispatch, 2_000)

      assert_receive {:quota_notice_dispatched, dispatched}
      assert dispatched.payload["text"] == "quota notice"
      assert dispatched.payload["reply_presentation"]["answer"] == "quota notice"

      assert {:error, :outbox_not_dispatchable} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter
               )

      refute_receive {:quota_notice_dispatched, _}, 100
    end

    test "tenant suspension notice does not stop another input's preview" do
      %{event: preview_event} = start_channel_reply_response_run()
      preview_pid = replace_with_late_preview(preview_event, "unrelated-preview")

      assert {:ok, %{actor_event: event}} =
               emit_entry(
                 preview_event.agent_uid,
                 preview_event.binding_name,
                 group_entry(%{source_entry_id: "suspended-next-input", explicit: true}),
                 now: DateTime.add(@base_time, 40, :second)
               )

      assert event.session_id == preview_event.session_id
      refute event.id == preview_event.id

      assert {:ok, outbox} =
               Repo.transact(fn repo ->
                 Outbox.commit_tenant_suspended_notice_outbox_in_tx(
                   repo,
                   event,
                   "suspended notice"
                 )
               end)

      parent = self()

      adapter =
        outbox_adapter([:reply_entry], fn dispatched ->
          send(parent, {:suspension_notice_dispatched, dispatched})
          {:ok, %{created_source_entry_id: "suspension-notice", raw_payload: %{}}}
        end)

      assert {:ok, %{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter,
                 reply_preview_settle_timeout_ms: 0
               )

      assert_receive {:suspension_notice_dispatched, dispatched}
      assert dispatched.payload["text"] == "suspended notice"
      assert Process.alive?(preview_pid)
      refute_receive {:late_reply_preview_stop_requested, ^preview_pid}, 100
      monitor = Process.monitor(preview_pid)
      send(preview_pid, :settle)
      assert_receive {:DOWN, ^monitor, :process, ^preview_pid, :normal}
    end

    test "dispatch waits for a late preview id and edits it instead of posting a duplicate reply" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("fast final"))

      preview_source_entry_id = "provider-preview-late"

      assert [{existing_preview_pid, _value}] =
               AIReplyPreview.lookup(event.id)

      existing_preview_monitor = Process.monitor(existing_preview_pid)
      assert :ok = AIReplyPreview.stop(event.id)

      assert_receive {:DOWN, ^existing_preview_monitor, :process, ^existing_preview_pid, :normal}

      preview_pid =
        start_supervised!(
          Supervisor.child_spec(
            {LateReplyPreview, {self(), event, preview_source_entry_id}},
            restart: :temporary
          )
        )

      assert_turn_completed(turn_ref, completed)
      assert_receive {:late_reply_preview_stop_requested, ^preview_pid}

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :reply
      assert is_nil(outbox.target_source_entry_id)

      parent = self()

      adapter =
        outbox_adapter([:edit_entry], fn dispatched ->
          send(parent, {:late_preview_final_dispatched, dispatched})

          {:ok,
           %{
             created_source_entry_id: "ignored-for-edit",
             raw_payload: %{"provider" => "test"}
           }}
        end)

      dispatch =
        Task.async(
          Repo.bind_tenant(fn ->
            SignalsGateway.dispatch_outbox(
              outbox.agent_uid,
              outbox.binding_name,
              outbox.outbound_key,
              adapter,
              reply_preview_settle_timeout_ms: 1_000
            )
          end)
        )

      refute_receive {:late_preview_final_dispatched, _outbox}, 100
      send(preview_pid, :settle)

      assert {:ok,
              %OutboxEntry{
                status: :succeeded,
                operation: :edit,
                target_source_entry_id: ^preview_source_entry_id
              }} = Task.await(dispatch, 2_000)

      assert_receive {:late_preview_final_dispatched,
                      %OutboxEntry{
                        operation: :edit,
                        target_source_entry_id: ^preview_source_entry_id
                      }}

      assert %Entry{
               source_entry_id: ^preview_source_entry_id,
               ai_message_id: ai_message_id,
               text: "fast final"
             } = Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
    end

    test "startup outbox recovery reclaims an orphan preview before terminal delivery" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("recovered final"))

      assert [{existing_preview_pid, _value}] =
               AIReplyPreview.lookup(event.id)

      existing_preview_monitor = Process.monitor(existing_preview_pid)
      assert :ok = AIReplyPreview.stop(event.id)
      assert_receive {:DOWN, ^existing_preview_monitor, :process, ^existing_preview_pid, :normal}

      assert_turn_completed(turn_ref, completed)
      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      preview_source_entry_id = "provider-preview-recovered"

      # Simulate a lifecycle process exiting after the terminal transaction
      # committed but before its stop cast reached the transient preview.
      preview_pid =
        start_supervised!(
          Supervisor.child_spec(
            {LateReplyPreview, {self(), event, preview_source_entry_id}},
            restart: :temporary
          )
        )

      parent = self()

      adapter =
        outbox_adapter([:edit_entry], fn dispatched ->
          send(parent, {:recovered_preview_final_dispatched, dispatched})
          {:ok, %{created_source_entry_id: "ignored-for-edit"}}
        end)

      dispatch =
        Task.async(
          Repo.bind_tenant(fn ->
            SignalsGateway.dispatch_outbox(
              outbox.agent_uid,
              outbox.binding_name,
              outbox.outbound_key,
              adapter,
              reply_preview_settle_timeout_ms: 1_000
            )
          end)
        )

      assert_receive {:late_reply_preview_stop_requested, ^preview_pid}
      refute_receive {:recovered_preview_final_dispatched, _outbox}, 100
      send(preview_pid, :settle)

      assert {:ok,
              %OutboxEntry{
                status: :succeeded,
                operation: :edit,
                target_source_entry_id: ^preview_source_entry_id
              }} = Task.await(dispatch, 2_000)

      assert_receive {:recovered_preview_final_dispatched,
                      %OutboxEntry{target_source_entry_id: ^preview_source_entry_id}}

      assert {:error, :outbox_not_dispatchable} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter
               )

      refute_receive {:recovered_preview_final_dispatched, _duplicate}, 100
    end

    test "a preview settle timeout leaves the final reply untouched and retryable" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("retryable final"))

      preview_source_entry_id = "provider-preview-after-timeout"

      assert [{existing_preview_pid, _value}] =
               AIReplyPreview.lookup(event.id)

      existing_preview_monitor = Process.monitor(existing_preview_pid)
      assert :ok = AIReplyPreview.stop(event.id)

      assert_receive {:DOWN, ^existing_preview_monitor, :process, ^existing_preview_pid, :normal}

      preview_pid =
        start_supervised!(
          Supervisor.child_spec(
            {LateReplyPreview, {self(), event, preview_source_entry_id}},
            restart: :temporary
          )
        )

      assert_turn_completed(turn_ref, completed)
      assert_receive {:late_reply_preview_stop_requested, ^preview_pid}

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      parent = self()

      adapter =
        outbox_adapter([:edit_entry], fn dispatched ->
          send(parent, {:timeout_preview_final_dispatched, dispatched})

          {:ok,
           %{
             created_source_entry_id: "ignored-for-edit",
             raw_payload: %{"provider" => "test"}
           }}
        end)

      assert {:error, :reply_preview_settle_timeout} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter,
                 reply_preview_settle_timeout_ms: 0
               )

      refute_receive {:timeout_preview_final_dispatched, _outbox}, 100

      assert %OutboxEntry{
               status: :created,
               operation: :reply,
               target_source_entry_id: nil,
               attempt_count: 0,
               platform_send_started_at: nil
             } =
               Repo.get_by!(OutboxEntry,
                 agent_uid: outbox.agent_uid,
                 binding_name: outbox.binding_name,
                 outbound_key: outbox.outbound_key
               )

      preview_monitor = Process.monitor(preview_pid)
      send(preview_pid, :settle)
      assert_receive {:DOWN, ^preview_monitor, :process, ^preview_pid, :normal}

      assert {:ok,
              %OutboxEntry{
                status: :succeeded,
                operation: :edit,
                target_source_entry_id: ^preview_source_entry_id,
                attempt_count: 1
              }} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter,
                 reply_preview_settle_timeout_ms: 0
               )

      assert_receive {:timeout_preview_final_dispatched,
                      %OutboxEntry{
                        operation: :edit,
                        target_source_entry_id: ^preview_source_entry_id
                      }}
    end

    test "an adapter edit fallback persists and mirrors the provider operation that happened" do
      %{message: message, event: event, turn_ref: turn_ref} = start_channel_reply_response_run()

      event
      |> ActorEvent.changeset(%{reply_preview_source_entry_id: "provider-preview"})
      |> Repo.update!()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("fallback final"))

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      assert outbox.operation == :edit

      adapter =
        outbox_adapter([:edit_entry], fn _outbox ->
          {:ok,
           %{
             created_source_entry_id: "provider-fallback-post",
             delivered_operation: :post,
             raw_payload: %{"provider" => "test", "fallback" => true}
           }}
        end)

      assert {:ok,
              %OutboxEntry{
                status: :succeeded,
                operation: :post,
                target_source_entry_id: nil,
                created_source_entry_id: "provider-fallback-post"
              }} =
               SignalsGateway.dispatch_outbox(
                 outbox.agent_uid,
                 outbox.binding_name,
                 outbox.outbound_key,
                 adapter
               )

      assert %Entry{
               source_entry_id: "provider-fallback-post",
               ai_message_id: ai_message_id,
               text: "fallback final"
             } = Repo.get_by!(Entry, ai_message_id: message.id)

      assert ai_message_id == message.id
    end

    test "Oban dispatches final reply outbox through the registered adapter" do
      MockOutbox.put_recipient(self())

      on_exit(fn ->
        MockOutbox.delete_recipient()
      end)

      %{message: message, turn_ref: turn_ref} = start_channel_reply_response_run()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("scheduled final"))

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")

      job =
        Repo.one!(
          from job in Oban.Job,
            where:
              job.worker == "Ankole.SignalsGateway.Jobs.OutboxDispatch" and
                fragment("?->>'outbound_key'", job.args) == ^outbox.outbound_key
        )

      assert :ok = Ankole.SignalsGateway.Jobs.OutboxDispatch.perform(job)

      key = outbox.outbound_key
      assert_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}, 1_000

      assert %Entry{ai_message_id: ai_message_id, text: "scheduled final"} =
               wait_for_entry!(completed.id)

      assert ai_message_id == completed.id
    end
  end

  defp replace_with_late_preview(event, source_entry_id) do
    [{pid, _}] = AIReplyPreview.lookup(event.id)
    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    start_supervised!(
      Supervisor.child_spec({LateReplyPreview, {self(), event, source_entry_id}},
        restart: :temporary
      )
    )
  end

  defp start_channel_reply_response_run do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 explicit: true,
                 source_event_id: "evt-#{System.unique_integer([:positive])}",
                 source_entry_id: "msg-#{System.unique_integer([:positive])}"
               }),
               now: @base_time
             )

    assert {:ok, turn_ref} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: event.session_id},
               event
             )

    assert {:ok, conversation} =
             Conversations.ensure_conversation(agent.uid, event.session_id)

    assert :ok = Ankole.Conversations.Presentation.start(turn_ref, self())

    assert {:ok, message} =
             start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: conversation.id,
               metadata: %{"request_metadata" => %{"actor_event_id" => event.id}}
             })

    %{agent: agent, event: event, message: message, turn_ref: turn_ref}
  end

  defp assert_turn_completed(turn_ref, message) do
    assert {:ok, _} =
             Run.finalize(
               %{turn_ref | anchor: message.id, model_response: message},
               "loop_finished"
             )
  end

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp adapter(capability, created_source_entry_id) do
    outbox_adapter([capability], fn _outbox ->
      {:ok,
       %{
         created_source_entry_id: created_source_entry_id,
         raw_payload: %{"provider" => "test"}
       }}
    end)
  end

  defp wait_for_entry!(ai_message_id, attempts_left \\ 20)

  defp wait_for_entry!(ai_message_id, attempts_left) when attempts_left > 0 do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        entry

      nil ->
        Process.sleep(10)
        wait_for_entry!(ai_message_id, attempts_left - 1)
    end
  end

  defp wait_for_entry!(ai_message_id, 0) do
    flunk("expected final reply mirror for ai_message_id=#{ai_message_id}")
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end
end
