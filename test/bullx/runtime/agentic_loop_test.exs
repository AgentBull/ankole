defmodule BullX.Runtime.AgenticLoopTest.Adapter do
  @behaviour BullX.Gateway.Adapter

  @impl true
  def config_schema, do: %{}

  @impl true
  def normalize_config(config), do: {:ok, config}

  @impl true
  def public_config(config), do: config

  @impl true
  def capabilities do
    %{
      inbound_modes: [:callback],
      outbound_ops: [:send],
      content_kinds: [:text],
      stream_strategy: :unsupported
    }
  end

  @impl true
  def connectivity_check(_source), do: {:ok, %{}}

  @impl true
  def source_child_spec(_source), do: :ignore

  @impl true
  def normalize_inbound(_payload, _source, _metadata), do: {:error, %{}}

  @impl true
  def deliver(delivery, _source) do
    send(test_pid(), {:gateway_delivered, delivery})
    {:ok, delivery_outcome(delivery)}
  end

  @impl true
  def stream(_delivery, _enumerable, _source), do: {:error, %{}}

  def put_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})

  defp delivery_outcome(delivery) do
    %{
      "delivery_id" => delivery.id,
      "status" => "sent",
      "external_message_ids" => ["reply_external_1"],
      "primary_external_id" => "reply_external_1",
      "warnings" => []
    }
  end
end

defmodule BullX.Runtime.AgenticLoopTest.LLMClient do
  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel
  alias ReqLLM.Context
  alias ReqLLM.Response

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, messages, _opts) do
    send(test_pid(), {:llm_chat, resolved, messages})

    {:ok,
     %Response{
       id: "fake-response",
       model: resolved.model_id,
       context: Context.new(messages),
       message: Context.assistant(reply_text()),
       object: nil,
       stream?: false,
       stream: nil,
       usage: %{input_tokens: 12, output_tokens: 5, total_tokens: 17},
       finish_reason: :stop,
       provider_meta: %{"request_id" => "fake-request"},
       error: nil
     }}
  end

  def put_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
  def put_reply_text(text), do: :persistent_term.put({__MODULE__, :reply_text}, text)

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  defp reply_text, do: :persistent_term.get({__MODULE__, :reply_text}, "bot reply")
end

defmodule BullX.Runtime.AgenticLoopTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.Gateway.{DeliveryIntent, Signal, SourceConfig}
  alias BullX.LLM.{PluginProviders, Provider, Writer}
  alias BullX.Plugins.{Extension, Registry, Spec}
  alias BullX.Principals
  alias BullX.Repo
  alias BullX.Runtime.AgenticLoop.Message
  alias BullX.Runtime.AgenticLoop.Session
  alias BullX.Runtime.AgenticLoopTest.{Adapter, LLMClient}
  alias BullX.Runtime.SignalRouting
  alias BullX.Runtime.SignalRouting.{Cache, RouteConsumer, RouteDecision}

  setup %{sandbox_owner: owner} do
    allow_process(BullX.Config.Cache, owner)
    allow_process(BullX.LLM.Catalog.Cache, owner)
    allow_process(Cache, owner)

    previous_gateway = Application.get_env(:bullx, :gateway)
    previous_llm = Application.get_env(:bullx, :llm)
    previous_registry = :sys.get_state(Registry)

    Application.put_env(
      :bullx,
      :gateway,
      previous_gateway
      |> Keyword.put(:outbound_dispatch_poll_ms, false)
      |> Keyword.put(:outbound_dispatch_listen?, false)
    )

    Application.put_env(:bullx, :llm, client: LLMClient)

    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    configure_registry!()
    configure_source!()
    configure_llm_provider!()
    SignalRouting.refresh_cache()

    Adapter.put_test_pid(self())
    LLMClient.put_test_pid(self())
    LLMClient.put_reply_text("hello from agent")

    on_exit(fn ->
      restore_env(:gateway, previous_gateway)
      restore_env(:llm, previous_llm)
      :sys.replace_state(Registry, fn _state -> previous_registry end)
      BullX.Config.delete("bullx.gateway.sources")
      Repo.delete_all(Provider)
      BullX.LLM.Catalog.Cache.refresh_all()
      SignalRouting.refresh_cache()
    end)

    :ok
  end

  test "routed Feishu-style group message reaches AgenticLoop and enqueues a reply" do
    agent = create_agent!("chatbot")
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("chatbot")))
    intent = single_intent!(inbound_signal())

    assert :ok = RouteConsumer.deliver(intent)

    assert_receive {:llm_chat, resolved, messages}, 1_000
    assert resolved.provider_id == "test_llm"
    assert resolved.model_id == "chat-model"
    assert Enum.map(messages, & &1.role) == [:system, :user]
    [system_message, user_message] = messages
    assert [%{text: system_text}] = system_message.content
    assert system_text =~ "Principal uid:"
    assert [%{text: "hello"}] = user_message.content

    decision = Repo.one!(from(decision in RouteDecision))
    session = Repo.one!(from(session in Session))

    messages =
      Repo.all(from message in Message, order_by: [asc: message.inserted_at])

    assert [%Message{} = user, %Message{} = assistant] = messages
    assert session.agent_principal_id == agent.principal.id
    assert session.current_leaf_message_id == assistant.id
    assert user.role == :user
    assert user.kind == :normal
    assert user.metadata["route_decision_id"] == decision.id
    assert user.metadata["input_mode"] == "mentioned_group"
    assert assistant.role == :assistant
    assert assistant.kind == :normal
    assert assistant.parent_id == user.id
    assert assistant.content == [%{"kind" => "text", "body" => %{"text" => "hello from agent"}}]

    assert_receive {:gateway_delivered, delivery}, 1_000
    assert delivery.reply_to_external_id == "message_1"
    assert delivery.scope_id == "chat_1"
    assert delivery.adapter == "feishu"
    assert get_in(delivery.content, [Access.at(0), "body", "text"]) == "hello from agent"

    assert :ok = RouteConsumer.deliver(intent)
    refute_receive {:llm_chat, _resolved, _messages}, 100
    refute_receive {:gateway_delivered, _delivery}, 100
    assert Repo.aggregate(Message, :count) == 2
  end

  test "new-session slash command closes the current session without calling the LLM" do
    agent = create_agent!("new_session")
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("new_session")))

    intent = single_intent!(inbound_signal(%{}, "/新会话"))

    assert :ok = RouteConsumer.deliver(intent)

    refute_receive {:llm_chat, _resolved, _messages}, 100

    sessions = Repo.all(from session in Session, order_by: [asc: session.inserted_at])

    assert [
             %Session{ended_at: %DateTime{}},
             %Session{ended_at: nil, current_leaf_message_id: nil}
           ] =
             sessions

    [command] = Repo.all(from(message in Message))
    assert command.kind == :command
    assert command.role == :user
    assert command.metadata["input_mode"] == "mentioned_group"
    assert command.metadata["command_alias"] == "/新会话"

    assert :ok = RouteConsumer.deliver(intent)
    refute_receive {:llm_chat, _resolved, _messages}, 100
    refute_receive {:gateway_delivered, _delivery}, 100
    assert Repo.aggregate(Message, :count) == 1
  end

  test "observed group input is persisted without generation when enabled on the Agent" do
    agent = create_agent!("observer", profile: %{"listen_all_group_messages" => true})
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("observer")))

    signal = inbound_signal(%{"routing_facts" => %{"bullx.input_mode" => "observed_group"}})

    assert :ok = RouteConsumer.deliver(single_intent!(signal))
    refute_receive {:llm_chat, _resolved, _messages}, 100

    [message] = Repo.all(from(message in Message))
    assert message.role == :user
    assert message.kind == :normal
    assert message.metadata["input_mode"] == "observed_group"
    refute_receive {:gateway_delivered, _delivery}, 100
  end

  defp create_agent!(suffix, opts \\ []) do
    profile =
      %{
        "main_llm" => "test_llm:chat-model",
        "goals" => "Talk with users in Feishu groups",
        "soul" => "Concise and useful"
      }
      |> Map.merge(Keyword.get(opts, :profile, %{}))

    assert {:ok, %{principal: principal, agent: agent}} =
             Principals.create_agent(%{
               principal: %{
                 uid: "agentic-loop-#{suffix}-#{System.unique_integer([:positive])}",
                 display_name: "Agentic Loop #{suffix}"
               },
               agent: %{profile: profile}
             })

    %{principal: principal, agent: agent}
  end

  defp agent_rule(agent, attrs) do
    %{
      key: unique_key("agentic_loop"),
      name: "AgenticLoop route",
      priority: 0,
      signal_type: "com.agentbull.x.inbound.received",
      adapter: "feishu",
      channel_id: "main",
      route_action: :deliver_agent,
      agent_principal_id: agent.principal.id,
      reason: "matched",
      metadata: %{}
    }
    |> Map.merge(Map.new(attrs))
  end

  defp single_intent!(signal) do
    assert {:ok, [%DeliveryIntent{} = intent]} =
             BullX.Runtime.SignalRouting.Router.resolve(signal)

    intent
  end

  defp inbound_signal(extra_data \\ %{}, text \\ "hello") do
    data =
      %{
        "content" => [%{"kind" => "text", "body" => %{"text" => text}}],
        "event" => %{
          "type" => "message",
          "name" => "feishu.im.message.receive_v1",
          "version" => 1,
          "data" => %{"message_id" => "message_1"}
        },
        "duplex" => true,
        "actor" => %{"id" => "ou_alice", "display" => "Alice", "bot" => false},
        "scope_id" => "chat_1",
        "thread_id" => "thread_1",
        "refs" => [%{"kind" => "feishu.message", "id" => "message_1"}],
        "reply_channel" => %{
          "adapter" => "feishu",
          "channel_id" => "main",
          "scope_id" => "chat_1",
          "thread_id" => "thread_1",
          "reply_to_external_id" => "message_1"
        },
        "provenance" => %{"event_id" => "event_1"},
        "routing_facts" => %{}
      }
      |> Map.merge(extra_data)

    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-14T00:00:00Z",
        "data" => data,
        "bullxoccurkey" => "feishu:event:#{System.unique_integer([:positive])}",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    signal
  end

  defp configure_registry! do
    extension = %Extension{
      plugin_id: "feishu",
      point: :"bullx.gateway.adapter",
      id: "feishu",
      module: Adapter
    }

    spec = %Spec{
      app: :feishu,
      id: "feishu",
      module: __MODULE__,
      api_version: 1,
      extensions: [extension]
    }

    state = %Registry{
      plugins: [spec],
      plugins_by_id: %{"feishu" => spec},
      enabled_ids: MapSet.new(["feishu"]),
      extensions: [extension]
    }

    :sys.replace_state(Registry, fn _state -> state end)
  end

  defp configure_source! do
    source = %{
      "adapter" => "feishu",
      "channel_id" => "main",
      "enabled" => true,
      "config" => %{},
      "outbound_retry" => %{"max_attempts" => 1}
    }

    {:ok, normalized} = SourceConfig.normalize(source)

    source =
      Map.put(source, "connectivity", %{
        "status" => "ok",
        "fingerprint" => SourceConfig.fingerprint(normalized),
        "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    BullX.Config.put("bullx.gateway.sources", Jason.encode!([source]))
  end

  defp configure_llm_provider! do
    assert {:ok, _provider} =
             Writer.put_provider(%{
               provider_id: "test_llm",
               req_llm_provider: "openai",
               provider_options: %{}
             })

    BullX.LLM.Catalog.Cache.refresh_all()
  end

  defp allow_process(name, owner) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, pid)
      nil -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)

  defp unique_key(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
