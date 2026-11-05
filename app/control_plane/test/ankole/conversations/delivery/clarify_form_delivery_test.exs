defmodule Ankole.Conversations.Delivery.ClarifyFormDeliveryTest do
  use Ankole.SessionsCase

  import Ankole.PrincipalsFixtures, only: [actor_fixture: 1]

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.{Interactions, PreviewStates, ReplyPresentation}
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Prompt.Input

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  @fields [
    %{
      "id" => "quantity",
      "label" => "Quantity",
      "type" => "number",
      "integer" => true,
      "min" => 1
    },
    %{
      "id" => "warehouses",
      "label" => "Warehouses",
      "type" => "multi_select",
      "options" => [
        %{"value" => "us_west", "label" => "US West"},
        %{"value" => "us_east", "label" => "US East"}
      ]
    }
  ]

  test "an external form posts its question with a Pod link and waits for one valid submission" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Dana"})
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    %{source: source, intent: intent} = ask_form(agent)

    ref = "#{source.id}:clarify:call-order"
    refute intent.payload["metadata"]["source"] == "ai_gateway_clarify"
    refute Map.has_key?(intent.payload, "interactive_output")
    assert intent.payload["text"] =~ "How should I ship it?"
    assert intent.payload["text"] =~ "- Quantity\n- Warehouses"
    assert intent.payload["text"] =~ "/?interaction=" <> URI.encode_www_form(ref)

    actor = actor_fixture(human)

    assert {:ok, %{"state" => "pending", "conversation_kind" => "external"} = view} =
             Interactions.standalone(actor, ref)

    assert view["question"] == "How should I ship it?"
    assert Enum.map(view["fields"], & &1["id"]) == ["quantity", "warehouses"]

    %{principal: suspended} = Ankole.PrincipalsFixtures.human_fixture()

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.disable(suspended.uid, "Away", nil, "form-away")

    assert {:error, :not_found} = Interactions.standalone(actor_fixture(suspended), ref)

    assert {:error, :reply_interaction_operator_unauthorized} =
             Interactions.answer_standalone(actor_fixture(suspended), ref, %{
               values: %{"quantity" => 1, "warehouses" => ["us_west"]}
             })

    assert {:error,
            {:invalid_form_answer, %{"quantity" => "out_of_range", "warehouses" => "required"}}} =
             Interactions.answer_standalone(actor, ref, %{values: %{"quantity" => 0}})

    assert PreviewStates.get(source.id).checkpoint["interactions"]["clarify:call-order"]["state"] ==
             "pending"

    assert action_events(agent.uid) == []

    assert {:ok, answered} =
             Ash.ActionInput.for_action(
               Ankole.Pod.Chat.Browser,
               :answer_standalone_interaction,
               %{
                 interaction_id: ref,
                 values: %{"quantity" => 300, "warehouses" => ["us_east", "us_west"]}
               },
               tenant: Repo.tenant_id!()
             )
             |> Ankole.Ash.run_action_authorized(actor)

    assert %{state: "answered", answered_by_name: "Dana", conversation_kind: "external"} =
             answered

    assert answered.answer_text == "Quantity: 300 · Warehouses: US West, US East"

    assert [wake] = action_events(agent.uid)
    assert wake.session_id == source.session_id
    assert wake.human_uid == human.uid
    assert wake.reply_binding_id == source.reply_binding_id

    assert get_in(wake.data, ["action", "value", "answer"]) == %{
             "kind" => "form",
             "value" => "Quantity: 300 · Warehouses: US West, US East",
             "values" => %{"quantity" => 300, "warehouses" => ["us_west", "us_east"]}
           }

    text = Input.text(Signal.envelope(wake), wake.type)
    assert text =~ "Answer: Quantity: 300 · Warehouses: US West, US East"
    assert text =~ ~s({"quantity":300,"warehouses":["us_west","us_east"]})

    assert {:error, :interaction_not_pending} =
             Interactions.answer_standalone(actor, ref, %{
               values: %{"quantity" => 1, "warehouses" => ["us_west"]}
             })

    # Another Human sees who answered, but only the answerer sees the answer.
    %{principal: colleague} = Ankole.PrincipalsFixtures.human_fixture()

    assert {:ok, %{"state" => "answered", "answered_by_name" => "Dana"} = other_view} =
             Interactions.standalone(actor_fixture(colleague), ref)

    assert other_view["answer_text"] == nil
    assert {:ok, %{"answer_text" => "Quantity: 300 " <> _}} = Interactions.standalone(actor, ref)
  end

  test "a later clarify from the same Agent supersedes the pending external form" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    %{source: source} = ask_form(agent)

    assert {:ok, wake} =
             Ankole.Signals.accept(%{
               producer: :kernel,
               source: "test://clarify-form",
               id: "form-follow-up",
               type: "background_agent_job.completed",
               time: @base_time,
               available_at: @base_time,
               target: %{agent_uid: agent.uid, session_id: source.session_id},
               authorization: Ankole.Principals.WorkAccess.service(),
               data: %{"job_id" => 1},
               reply_route: %{
                 binding_id: source.reply_binding_id,
                 binding_name: source.reply_binding_name,
                 conversation_id: source.conversation_id,
                 provider_thread_id: source.provider_thread_id,
                 provider_message_id: source.provider_message_id
               }
             })

    assert pending?(source)
    complete_clarify(wake, "call-follow-up", %{"question" => "Which carrier?", "choices" => []})

    interaction = PreviewStates.get(source.id).checkpoint["interactions"]["clarify:call-order"]
    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_signal_id"] == wake.id

    assert PreviewStates.get(wake.id).checkpoint["interactions"]["clarify:call-follow-up"][
             "state"
           ] == "pending"
  end

  test "a form-capable channel renders the form and validates each card submission" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Dana"})
    binding = binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-rich-provider")
    %{source: source, intent: intent} = ask_form(agent)

    ref = "#{source.id}:clarify:call-order"
    assert intent.payload["metadata"]["source"] == "ai_gateway_clarify"
    assert intent.fallback_visible_text =~ "/?interaction=" <> URI.encode_www_form(ref)
    # The card body leaves the link to its button, so the card shows it once.
    refute intent.payload["text"] =~ "/?interaction="

    assert [form, link] = intent.payload["reply_presentation"]["actions"]
    assert form["type"] == "form"
    assert form["control_id"] == "clarify-form"
    assert form["interaction_id"] == "clarify:call-order"

    assert Enum.map(form["fields"], &{&1["id"], &1["type"]}) == [
             {"quantity", "number"},
             {"warehouses", "multi_select"}
           ]

    assert link["type"] == "link"
    assert link["url"] =~ "/?interaction=" <> URI.encode_www_form(ref)

    assert {:ok, callback} = ReplyPresentation.callback_value(source.id, form)
    assert callback["answerKind"] == "form"

    # The provider confirms the card, so its callbacks name that entry.
    assert :ok = PreviewStates.record_provider_message(source.id, "form-card")

    submit = fn values, event_id ->
      Observe.emit_action(binding.id, %{
        source_event_id: event_id,
        action_id: event_id,
        provider_conversation_id: "lark:chat:form",
        provider_message_id: "form-card",
        provider_thread_id: source.provider_thread_id,
        action: %{
          "name" => "clarify-form",
          "value" => Map.put(callback, "formValue", values),
          "operator_principal_uid" => human.uid
        }
      })
    end

    assert {:ok, %{status: :invalid_form_answer, notice: notice}} =
             submit.(%{"quantity" => "2.5"}, "form-card-invalid")

    assert notice =~ "Quantity (not a whole number)"
    assert notice =~ "Warehouses (required)"
    assert pending?(source)
    assert action_events(agent.uid) == []

    assert {:ok, %{status: :accepted, signal: wake}} =
             submit.(%{"quantity" => "300", "warehouses" => "us_east,us_west"}, "form-card-ok")

    assert get_in(wake.data, ["action", "value", "answer"]) == %{
             "kind" => "form",
             "value" => "Quantity: 300 · Warehouses: US West, US East",
             "values" => %{"quantity" => 300, "warehouses" => ["us_west", "us_east"]}
           }

    checkpoint = PreviewStates.get(source.id).checkpoint
    refute pending?(source)

    assert checkpoint["presentation"]["interaction_answer"] ==
             "Quantity: 300 · Warehouses: US West, US East"

    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])

    assert {:ok, %{status: :duplicate_action}} =
             submit.(%{"quantity" => "300", "warehouses" => "us_east,us_west"}, "form-card-again")

    assert {:ok, %{status: :stale_action}} =
             submit.(%{"quantity" => "1", "warehouses" => "us_west"}, "form-card-late")

    assert length(action_events(agent.uid)) == 1
  end

  defp ask_form(agent) do
    assert {:ok, %{signal: source}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "form-source",
                 provider_conversation_id: "lark:chat:form",
                 provider_message_id: "form-message",
                 text: "Ship the order.",
                 explicit: true
               }),
               now: @base_time
             )

    intent =
      complete_clarify(source, "call-order", %{
        "question" => "How should I ship it?",
        "choices" => [],
        "fields" => @fields
      })

    %{source: source, intent: intent}
  end

  defp complete_clarify(source, call_id, output) do
    assert {:ok, run} = Admission.admit(key(source), source, now: @base_time)

    response =
      complete_aigateway_turn!(run, "",
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "Ship the order."}]
          }
        ],
        output_items: [
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "clarify",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => Map.merge(%{"tool" => "clarify", "ok" => true}, output)
          }
        ]
      )

    assert {:ok, %{status: :completed, posted: %{intents: [intent]}}} =
             commit_turn_completion(run, "resp_#{response.id}", :loop_finished)

    intent
  end

  defp pending?(source),
    do:
      PreviewStates.get(source.id).checkpoint["interactions"]["clarify:call-order"]["state"] ==
        "pending"

  defp key(event), do: %{agent_uid: event.agent_uid, session_id: event.session_id}

  defp action_events(agent_uid) do
    Repo.all(
      from(event in Signal,
        where: event.agent_uid == ^agent_uid and event.type == "signal.action.invoked"
      )
    )
  end
end
