defmodule Ankole.Signals.CloudEventsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Signals.{Binding, Bindings, CloudEvents, Signal, Webhooks}

  setup do
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    assert {:ok, endpoint} =
             Webhooks.create_endpoint(%{
               label: "Issue changes",
               mode: "standing",
               event_format: "cloudevents",
               expires_at: DateTime.add(now, 1, :hour)
             })

    %{first: first, second: second, endpoint: endpoint.webhook_endpoint, token: endpoint.token}
  end

  test "subscriptions and raw endpoints reject private work sessions but permit custom sessions",
       context do
    for session <- ["job:123", "wf_task:456"] do
      assert {:error, :invalid_signal_target} =
               Bindings.put_binding(context.first.uid, "cloudevents", "private", %{
                 "config" => %{"webhook_endpoint_id" => context.endpoint.id},
                 "target" => %{"session_id" => session}
               })

      assert {:error, :invalid_signal_target} =
               Webhooks.create_endpoint(%{
                 agent_uid: context.first.uid,
                 session_id: session,
                 label: "Private target",
                 mode: "standing",
                 expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)
               })
    end

    refute Repo.exists?(Binding)
    bind!(context, context.first, "custom", "custom:triage")
    assert {:ok, %{signals: [signal]}} = Webhooks.receive_cloudevent(context.token, event())
    assert signal.session_id == "custom:triage"
    assert signal.producer == :external
  end

  test "endpoint subscriptions filter, fan out, retain original identity, and deduplicate",
       context do
    bind!(context, context.first, "first", "triage:first")

    bind!(context, context.second, "second", "triage:second", %{
      "cel" => "signal.type == 'issue.changed' && signal.data.priority == 'urgent'"
    })

    assert {:ok, %{signals: [first, second], status: :accepted}} =
             Webhooks.receive_cloudevent(context.token, event())

    assert MapSet.new([first.agent_uid, second.agent_uid]) ==
             MapSet.new([context.first.uid, context.second.uid])

    for signal <- [first, second] do
      assert signal.source == event()["source"]
      assert signal.source_event_id == event()["id"]
      assert signal.type == event()["type"]
      assert signal.data == event()["data"]
      assert is_nil(signal.subject)
      assert signal.authorization_kind == "service"
      assert is_nil(signal.sender_key)

      assert_enqueued(
        worker: Ankole.Sessions.Jobs.EnsureDriver,
        args: %{agent_uid: signal.agent_uid, session_id: signal.session_id}
      )
    end

    assert {:ok, %{signals: repeated}} = Webhooks.receive_cloudevent(context.token, event())
    assert Enum.map(repeated, & &1.id) == Enum.map([first, second], & &1.id)
    assert Repo.aggregate(Signal, :count) == 2

    ordinary = %{event() | "id" => "ordinary", "data" => %{"priority" => "ordinary"}}
    assert {:ok, %{signals: [only]}} = Webhooks.receive_cloudevent(context.token, ordinary)
    assert only.agent_uid == context.first.uid
  end

  test "scalar, array, false, and null event data keep their JSON value", context do
    bind!(context, context.first, "json-values", "json-values")

    for {data, index} <- Enum.with_index([42, "changed", [1, false, nil], false, nil]) do
      event = %{event() | "id" => "value-#{index}", "data" => data}
      assert {:ok, %{signals: [signal]}} = Webhooks.receive_cloudevent(context.token, event)
      assert Repo.reload!(signal).data === data
      assert Signal.envelope(signal)["data"] === data
    end
  end

  test "moving a subscription rejects an enabled target without changing either route", context do
    bind!(context, context.first, "shared-name", "source-session")
    bind!(context, context.second, "shared-name", "target-session")
    source = Repo.get_by!(Binding, agent_uid: context.first.uid, name: "shared-name")
    target = Repo.get_by!(Binding, agent_uid: context.second.uid, name: "shared-name")

    assert {:error, :binding_target_conflict} =
             Bindings.update_binding(context.first.uid, context.second.uid, "shared-name", %{
               "config" => %{}
             })

    assert Repo.get_by!(Binding, agent_uid: source.agent_uid, name: source.name) == source
    assert Repo.get_by!(Binding, agent_uid: target.agent_uid, name: target.name) == target
  end

  test "moving a subscription may use an unused name or replace a disabled target", context do
    for disabled_target? <- [false, true] do
      name = "move-#{disabled_target?}"
      bind!(context, context.first, name, "source-session")

      if disabled_target? do
        bind!(context, context.second, name, "disabled-session")

        Repo.get_by!(Binding, agent_uid: context.second.uid, name: name)
        |> Binding.changeset(%{enabled: false})
        |> Repo.update!()
      end

      assert {:ok, %{binding: moved}} =
               Bindings.update_binding(
                 context.first.uid,
                 context.second.uid,
                 name,
                 %{"config" => %{}}
               )

      assert moved.agent_uid == context.second.uid
      assert moved.target == %{"session_id" => "source-session"}
      assert moved.enabled
      refute Repo.get_by(Binding, agent_uid: context.first.uid, name: name)
    end
  end

  test "fixed configuration updates preserve their target and filtering", context do
    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(context.first.uid, "cloudevents", "configured", %{
               "config" => %{
                 "webhook_endpoint_id" => context.endpoint.id,
                 "target_kind" => "session",
                 "target_id" => "fixed-events"
               }
             })

    assert {:ok, %{config: config}} =
             Bindings.get_binding_configuration(context.first.uid, binding.name)

    assert config["target_kind"] == "session"
    assert config["target_id"] == "fixed-events"

    assert {:ok, %{binding: updated}} =
             Bindings.update_binding(context.first.uid, context.first.uid, binding.name, %{
               "config" => %{"filter_cel" => "signal.type == 'issue.changed'"}
             })

    assert updated.target == %{"session_id" => "fixed-events"}
    assert {:ok, %{signals: [signal]}} = Webhooks.receive_cloudevent(context.token, event())
    assert signal.session_id == "fixed-events"
    assert signal.source_event_id == event()["id"]
  end

  test "standard optional attributes and legal extension facts survive persistence and codec",
       context do
    bind!(context, context.first, "extensions", "extensions")

    event =
      Map.merge(event(), %{
        "datacontenttype" => "application/json",
        "dataschema" => "https://example.com/issue.schema.json",
        "traceparent" => "00-trace",
        "attempt" => 3,
        "urgent" => true
      })

    assert {:ok, %{signals: [signal]}} = Webhooks.receive_cloudevent(context.token, event)
    loaded = Repo.reload!(signal)

    for key <- ~w(datacontenttype dataschema traceparent attempt urgent) do
      assert loaded.extensions[key] == event[key]
      assert Signal.envelope(loaded)[key] == event[key]
    end

    assert Signal.envelope(%{loaded | extensions: %{"source" => "must-not-override"}})["source"] ==
             loaded.source

    assert {:error, :invalid_cloudevent_extension} =
             Webhooks.receive_cloudevent(context.token, Map.put(event, "nested", %{}))
  end

  test "a malformed subscription rolls back the complete fanout", context do
    [valid, invalid] = Enum.sort_by([context.first, context.second], & &1.uid)
    bind!(context, valid, "valid", "valid-session")

    Repo.insert!(
      Binding.changeset(%Binding{}, %{
        agent_uid: invalid.uid,
        name: "missing-conversation",
        adapter: "cloudevents",
        config_ref: "webhook-endpoint://#{context.endpoint.id}",
        target: %{"conversation_id" => Ecto.UUID.generate()}
      })
    )

    assert {:error, :conversation_not_found} =
             Webhooks.receive_cloudevent(context.token, event())

    assert Repo.aggregate(Signal, :count) == 0

    refute_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: valid.uid, session_id: "valid-session"}
    )
  end

  test "subscriptions require the participating Agent and preserve native conversation identity",
       context do
    %{principal: human} = human_fixture()
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Repo.transact(fn _ ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: context.first.uid,
                 text: "Watch issue changes."
               })
             end)

    config = %{"webhook_endpoint_id" => context.endpoint.id}
    attrs = %{"config" => config, "target" => %{"conversation_id" => id}}

    assert {:error, :conversation_not_found} =
             Bindings.put_binding(context.second.uid, "cloudevents", "wrong", attrs)

    assert {:ok, _} = Bindings.put_binding(context.first.uid, "cloudevents", "native", attrs)
    assert {:ok, %{signals: [signal]}} = Webhooks.receive_cloudevent(context.token, event())
    assert signal.conversation_id == id
    assert signal.session_id == "conversation:#{id}"
    assert is_nil(signal.reply_binding_name)
  end

  test "one external conversation routes independently to each participating Agent", context do
    alias Ankole.Conversations.External
    now = DateTime.utc_now(:microsecond)
    observation = %{provider_conversation_id: "mock:shared-room", external_kind: :im_group}

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               with {:ok, first} <-
                      External.observe_conversation_in_tx(
                        repo,
                        %{agent_uid: context.first.uid},
                        observation,
                        now
                      ),
                    {:ok, second} <-
                      External.observe_conversation_in_tx(
                        repo,
                        %{agent_uid: context.second.uid},
                        observation,
                        now
                      ) do
                 assert first.id == second.id
                 {:ok, second}
               end
             end)

    for {agent, name} <- [{context.first, "shared-first"}, {context.second, "shared-second"}] do
      assert {:ok, _} =
               Bindings.put_binding(agent.uid, "cloudevents", name, %{
                 "config" => %{"webhook_endpoint_id" => context.endpoint.id},
                 "target" => %{"conversation_id" => conversation.id}
               })
    end

    assert {:ok, %{signals: signals}} = Webhooks.receive_cloudevent(context.token, event())
    assert length(signals) == 2
    assert Enum.all?(signals, &(&1.conversation_id == conversation.id))

    assert Enum.map(signals, & &1.session_id) |> Enum.uniq() == [
             "conversation:#{conversation.id}"
           ]

    assert MapSet.new(signals, & &1.agent_uid) ==
             MapSet.new([context.first.uid, context.second.uid])

    assert {:error, :conversation_not_found} =
             Ankole.Signals.accept(%{
               source: "test://ambiguous-target",
               id: "one",
               type: "issue.changed",
               target: {:conversation, conversation.id},
               authorization: Ankole.Principals.WorkAccess.service(),
               data: %{}
             })
  end

  test "endpoint format, capability, expiry and unsupported facts fail without signals",
       context do
    bind!(context, context.first, "source", "source")

    assert {:error, :webhook_endpoint_not_found} =
             Webhooks.receive_cloudevent("wh_" <> String.duplicate("x", 43), event())

    assert {:error, :webhook_endpoint_not_found} = Webhooks.receive(context.token, [], "raw body")

    assert {:error, :invalid_cloudevent_extension} =
             Webhooks.receive_cloudevent(context.token, Map.put(event(), "Bad_Name", "trace"))

    assert {:error, :invalid_cloudevent} =
             Webhooks.receive_cloudevent(context.token, %{event() | "id" => "a" <> <<0>>})

    assert {:ok, %{status: :ignored}} =
             Webhooks.receive_cloudevent(context.token, event(),
               now: DateTime.add(context.endpoint.expires_at, 1, :second)
             )

    assert Repo.aggregate(Signal, :count) == 0
    assert {:ok, event} = CloudEvents.normalize(event())
    refute Map.has_key?(event, "subject")
  end

  test "invalid CloudEvents context attributes do not persist or wake a session", context do
    bind!(context, context.first, "validated-source", "validated-source")

    for {key, value} <- [
          {"source", "not a URI"},
          {"source", "bad%ZZ"},
          {"dataschema", "/relative-schema"},
          {"datacontenttype", "not-a-media-type"},
          {"type", "invalid" <> <<0xFDD0::utf8>>}
        ] do
      assert {:error, :invalid_cloudevent} =
               Webhooks.receive_cloudevent(context.token, Map.put(event(), key, value))
    end

    assert Repo.aggregate(Signal, :count) == 0

    refute_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: context.first.uid, session_id: "validated-source"}
    )

    assert {:ok, %{signals: [signal]}} =
             Webhooks.receive_cloudevent(
               context.token,
               event() |> Map.put("source", "/issues") |> Map.put("trace", "")
             )

    assert signal.source == "/issues"
    assert Signal.envelope(signal)["trace"] == ""
  end

  defp event do
    %{
      "specversion" => "1.0",
      "source" => "https://example.com/issues",
      "id" => "change-one",
      "type" => "issue.changed",
      "data" => %{"priority" => "urgent"}
    }
  end

  defp bind!(context, agent, name, session, filters \\ %{}) do
    assert {:ok, _} =
             Bindings.put_binding(agent.uid, "cloudevents", name, %{
               "config" => %{"webhook_endpoint_id" => context.endpoint.id},
               "target" => %{"session_id" => session},
               "filters" => filters
             })
  end
end
