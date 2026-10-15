defmodule Ankole.Sessions.ExternalRetryTest do
  use Ankole.SessionsCase
  alias Ankole.Sessions.Commands

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  for {type, data} <- [
        {"cron.fire", nil},
        {"command.steer", false},
        {"command.stop", [1, %{"producer" => "kernel"}]},
        {"custom.event", "unaltered scalar"}
      ] do
    test "a real /retry preserves external #{type} data and its private provenance" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      now = DateTime.add(@base_time, 30)

      {:ok, %{signal: initial}} =
        emit_entry(
          agent.uid,
          "bot",
          group_entry(%{text: "Establish this conversation", explicit: true}),
          now: now
        )

      {:ok, source} =
        Repo.transact(fn repo ->
          with {:ok, source} <-
                 Ankole.Signals.accept_in_tx(repo, %{
                   source: "https://example.test/event",
                   id: Ecto.UUID.generate(),
                   type: unquote(type),
                   data: unquote(Macro.escape(data)),
                   extensions: %{"producer" => "kernel", "traceparent" => "retained"},
                   target: %{agent_uid: agent.uid, session_id: initial.session_id},
                   authorization: Ankole.Principals.WorkAccess.service(),
                   reply_route: %{binding_name: "bot", conversation_id: initial.conversation_id}
                 }) do
            Queue.mark_event_dead_letter_in_tx(repo, source, now, "provider_failed")
          end
        end)

      {:ok, %{intents: [notice]}} =
        Repo.transact(
          &Ankole.Sessions.Notices.post_in_tx(
            &1,
            source,
            :dead_letter,
            "The external event failed"
          )
        )

      assert {:ok, %Intent{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 notice.agent_uid,
                 notice.binding_name,
                 notice.outbound_key,
                 delivery_adapter([:post_entry, :reply_entry, :edit_entry], fn _ ->
                   provider_id = Ecto.UUID.generate()

                   {:ok,
                    %{
                      created_provider_message_id: provider_id,
                      messages: [
                        %{
                          created_provider_message_id: provider_id,
                          text: "The external event failed",
                          raw_payload: %{"confirmed" => true}
                        }
                      ],
                      raw_payload: %{"confirmed" => true}
                    }}
                 end)
               )

      {:ok, %{signal: command}} =
        emit_entry(
          agent.uid,
          "bot",
          group_entry(%{
            text: "/retry signal::#{source.id}",
            provider_message_id: Ecto.UUID.generate(),
            explicit: true
          }),
          now: DateTime.add(now, 1)
        )

      assert command.producer == :kernel
      assert get_in(command.data, ["command", "targetSignalId"]) == source.id

      assert {:ok, %Signal{} = retry} =
               Commands.process(%{agent_uid: agent.uid, session_id: source.session_id}, command)

      assert retry.producer == :external
      refute Signal.produced_by_kernel?(retry)
      assert retry.data === source.data
      assert retry.data === unquote(Macro.escape(data))
      assert retry.extensions == source.extensions
      assert retry.subject == source.subject
      assert retry.type == source.type
      assert Repo.get!(Signal, source.id).data === source.data
      assert Repo.get!(Signal, source.id).producer == :external
      assert Repo.get!(Signal, source.id).input_state == "dead_letter"
      assert Commands.route(retry) == :run
    end
  end
end
