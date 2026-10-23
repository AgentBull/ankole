defmodule Ankole.Signals.AdaptersTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewState

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec
  alias Ankole.Plugins.LarkAdapter.Delivery, as: LarkDelivery
  alias Ankole.Signals.Adapters
  alias Ankole.Signals.Adapters.Definition
  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.Conversations.Delivery.Adapter
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.PreviewAdapter

  defmodule StringKeyDelivery do
    @moduledoc false

    def deliver(_intent), do: {:ok, %{created_provider_message_id: "string-key-result"}}
  end

  defmodule StringKeyPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.Signals.AdaptersTest.StringKeyDelivery

    @impl true
    def plugin_id, do: "string-key-signal-adapter"

    @impl true
    def adapter_declarations do
      [
        %{
          "contract_id" => "signals.adapter",
          "id" => "string-key",
          "adapter_category" => "enterprise_im",
          "plugin_id" => plugin_id(),
          "display_name" => %{"default" => "String Key Adapter"},
          "deliver_module" => StringKeyDelivery,
          "outbound_capabilities" => ["post_entry"]
        }
      ]
    end
  end

  defmodule InboundOnlyPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "inbound-only-signal-adapter"

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "inbound-only",
          adapter_category: "enterprise_im",
          plugin_id: plugin_id()
        }
      ]
    end
  end

  setup do
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
      Cache.clear_for_test()
    end)

    :ok
  end

  test "resolves the Lark declaration into one normalized adapter definition" do
    assert {:ok,
            %Definition{
              id: "lark",
              adapter_category: "enterprise_im",
              delivery_adapter: %Adapter{} = delivery_adapter
            }} = Adapters.fetch("lark")

    assert Adapter.capabilities(delivery_adapter) ==
             MapSet.new([
               :post_entry,
               :reply_entry,
               :edit_entry,
               :delete_entry,
               :add_reaction,
               :remove_reaction,
               :divider,
               :card,
               :outbound_reconciliation
             ])

    assert delivery_adapter.deliver_fun == (&LarkDelivery.deliver/1)
    assert delivery_adapter.reconcile_fun == (&LarkDelivery.reconcile/1)
  end

  test "requires one known display category on every signal adapter declaration" do
    assert :ok =
             Adapters.validate_declaration(%{
               id: "consumer",
               adapter_category: "consumer_im"
             })

    assert {:error, {:invalid_adapter_category, nil}} =
             Adapters.validate_declaration(%{id: "missing-category"})

    assert {:error, {:invalid_adapter_category, "social_media"}} =
             Adapters.validate_declaration(%{
               id: "unknown-category",
               adapter_category: "social_media"
             })
  end

  test "only one application binding is a supported declaration and needs a config module" do
    declaration = %{
      id: "application-owner",
      adapter_category: "consumer_im",
      config_module: Ankole.Plugins.LineAdapter.Config,
      application_bindings: :one
    }

    assert :ok = Adapters.validate_declaration(declaration)
    assert :ok = Adapters.validate_declaration(Map.delete(declaration, :application_bindings))

    assert {:error, {:invalid_application_bindings, :many}} =
             Adapters.validate_declaration(%{declaration | application_bindings: :many})

    assert {:error, {:missing_adapter_module, :config_module}} =
             Adapters.validate_declaration(Map.delete(declaration, :config_module))

    assert {:ok, definitions} = Adapters.list()

    assert for(
             definition <- definitions,
             definition.application_bindings == :one,
             do: definition.id
           )
           |> Enum.sort() == ["email", "lark", "line", "whatsapp"]
  end

  test "classifies existing enterprise adapters and Telegram without changing their contract" do
    assert {:ok, definitions} = Adapters.list()

    categories = Map.new(definitions, &{&1.id, &1.adapter_category})

    assert Map.take(categories, ["dingtalk", "lark", "slack", "teams", "wecom"]) == %{
             "dingtalk" => "enterprise_im",
             "lark" => "enterprise_im",
             "slack" => "enterprise_im",
             "teams" => "enterprise_im",
             "wecom" => "enterprise_im"
           }

    assert categories["telegram"] == "consumer_im"
  end

  test "resolves an atom-key declaration through the normalized interface" do
    registry = start_registry!([MockSignalProviderPlugin])

    assert {:ok, %Adapter{} = mock} =
             Adapters.fetch_delivery("mock-provider", registry)

    assert Adapter.capabilities(mock) ==
             MapSet.new([:post_entry, :reply_entry, :edit_entry, :outbound_reconciliation])
  end

  test "rejects string-key callback declarations" do
    assert {:error, _reason} = Spec.from_module(StringKeyPlugin)
  end

  test "returns one error vocabulary for unavailable, missing, and inbound-only adapters" do
    missing_registry = :"missing_signal_adapter_registry_#{System.unique_integer([:positive])}"

    assert {:error, :signal_adapter_registry_unavailable} =
             Adapters.fetch("lark", missing_registry)

    assert {:error, {:signal_adapter_not_found, "missing"}} = Adapters.fetch("missing")

    registry = start_registry!([InboundOnlyPlugin])

    assert {:ok, %Definition{id: "inbound-only", delivery_adapter: nil}} =
             Adapters.fetch("inbound-only", registry)

    assert {:error, {:signal_adapter_intent_unavailable, "inbound-only"}} =
             Adapters.fetch_delivery("inbound-only", registry)
  end

  test "rejects string-key intent callback results" do
    adapter = %Adapter{
      capabilities: MapSet.new([:post_entry]),
      deliver_fun: fn _intent -> {:ok, %{"created_provider_message_id" => "provider-id"}} end,
      reconcile_fun: nil
    }

    assert {:error, {:invalid_adapter_result_key, "created_provider_message_id"}} =
             Adapter.deliver(adapter, %{})
  end

  test "rejects string-key reply preview callback results" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "string-key-preview", :ignore)

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        "string-key-preview",
        group_entry(%{
          source_event_id: "string-key-preview-event",
          provider_message_id: "string-key-preview-msg",
          explicit: true
        })
      )

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request -> {:ok, %{"created_provider_message_id" => "provider-id"}} end,
      finalize_fun: fn _request -> {:ok, %{}} end,
      refresh_fun: nil
    }

    request = %PreviewAdapter.Request{
      signal: event,
      presentation: %{},
      mode: :working
    }

    assert {:error, {:invalid_preview_adapter_result_key, "created_provider_message_id"}} =
             PreviewAdapter.update(adapter, request)
  end

  test "filters only exact WorkerEnv secret values before intent delivery" do
    %{principal: agent} = agent_fixture()

    {worker_env_secret, visible_env_value} = configure_runtime_secrets!(agent.uid)

    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZ2VudCJ9.signature123"
    bearer = "Bearer example-token-for-documentation"
    private_key = "-----BEGIN PRIVATE KEY-----\nexample material\n-----END PRIVATE KEY-----"
    assignment = "api_key=plain-labeled-example"
    short_secret = "prod"

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent.uid, "EXAMPLE_SHORT", %{
               "value" => short_secret,
               "secret" => true
             })

    text =
      "custom #{worker_env_secret}; " <>
        "visible #{visible_env_value}; jwt #{jwt}; #{bearer}; #{assignment}\n#{private_key}\n" <>
        "the #{short_secret} deployment"

    parent = self()

    adapter = %Adapter{
      capabilities: MapSet.new([:post_entry]),
      deliver_fun: fn intent ->
        send(parent, {:filtered_intent, intent})
        {:ok, %{}}
      end,
      reconcile_fun: nil
    }

    intent = %Intent{
      agent_uid: agent.uid,
      payload: %{"text" => text, "nested" => [text]},
      fallback_visible_text: text
    }

    assert {:ok, %{}} = Adapter.deliver(adapter, intent)
    assert_receive {:filtered_intent, %Intent{} = filtered}

    rendered = inspect(filtered)
    refute rendered =~ worker_env_secret
    assert rendered =~ "[REDACTED]"

    filtered_text = filtered.fallback_visible_text
    assert filtered_text =~ visible_env_value
    assert filtered_text =~ jwt
    assert filtered_text =~ bearer
    assert filtered_text =~ assignment
    assert filtered_text =~ private_key
    assert filtered_text =~ "the #{short_secret} deployment"
  end

  test "filters runtime secrets before a rich reply preview adapter runs" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "filtered-preview", :ignore)

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        "filtered-preview",
        group_entry(%{
          source_event_id: "filtered-preview-event",
          provider_message_id: "filtered-preview-msg",
          explicit: true
        })
      )

    {worker_env_secret, _visible_env_value} = configure_runtime_secrets!(agent.uid)

    # The reloaded checkpoint feeds `checkpoint`, `previous_presentation`, and
    # the Signal copy, so the stored secret must vanish from all three.
    {:ok, _event} =
      PreviewStates.put_checkpoint(event.id, %{
        "presentation" => %{"answer" => "#{worker_env_secret} #{worker_env_secret}"}
      })

    parent = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn request ->
        send(parent, {:filtered_preview, request})
        {:ok, %{}}
      end,
      finalize_fun: fn _request -> {:ok, %{}} end,
      refresh_fun: nil
    }

    request = %PreviewAdapter.Request{
      signal: event,
      presentation: %{"answer" => "answer #{worker_env_secret}"},
      delivery: %Intent{
        agent_uid: agent.uid,
        payload: %{"text" => worker_env_secret},
        fallback_visible_text: worker_env_secret
      },
      mode: :working
    }

    assert {:ok, %{}} = PreviewAdapter.update(adapter, request)
    assert_receive {:filtered_preview, %PreviewAdapter.Request{} = filtered}

    assert filtered.signal.id == event.id
    assert filtered.checkpoint["presentation"] == %{"answer" => "[REDACTED] [REDACTED]"}
    assert filtered.previous_presentation == %{"answer" => "[REDACTED] [REDACTED]"}

    rendered = inspect(filtered)
    refute rendered =~ worker_env_secret
    assert rendered =~ "[REDACTED]"
  end

  defp start_registry!(modules) do
    name = :"signal_adapter_registry_#{System.unique_integer([:positive])}"

    assert {:ok, _enabled_ids} = Config.put_enabled_ids(Enum.map(modules, & &1.plugin_id()))

    start_supervised!(
      {Registry, name: name, modules: modules},
      id: name
    )

    name
  end

  defp configure_runtime_secrets!(agent_uid) do
    worker_env_secret = "custom-runtime-value-#{System.unique_integer([:positive])}"
    visible_env_value = "visible-runtime-value-#{System.unique_integer([:positive])}"

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent_uid, "EXAMPLE_CREDENTIAL", %{
               "value" => worker_env_secret,
               "secret" => true
             })

    assert {:ok, _item} =
             WorkerEnv.console_put_for_agent(agent_uid, "EXAMPLE_VISIBLE", %{
               "value" => visible_env_value,
               "secret" => false
             })

    {worker_env_secret, visible_env_value}
  end
end
