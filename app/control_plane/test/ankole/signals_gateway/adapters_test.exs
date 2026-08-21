defmodule Ankole.SignalsGateway.AdaptersTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  defmodule StringKeyOutbox do
    @moduledoc false

    def send(_outbox), do: {:ok, %{created_source_entry_id: "string-key-result"}}
  end

  defmodule StringKeyPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.SignalsGateway.AdaptersTest.StringKeyOutbox

    @impl true
    def plugin_id, do: "string-key-signal-adapter"

    @impl true
    def adapter_declarations do
      [
        %{
          "contract_id" => "signals_gateway.adapter",
          "id" => "string-key",
          "adapter_category" => "enterprise_im",
          "plugin_id" => plugin_id(),
          "display_name" => %{"default" => "String Key Adapter"},
          "outbox_module" => StringKeyOutbox,
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
          contract_id: "signals_gateway.adapter",
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
              outbox_adapter: %OutboxAdapter{} = outbox_adapter
            }} = Adapters.fetch("lark")

    assert OutboxAdapter.capabilities(outbox_adapter) ==
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

    assert outbox_adapter.send_fun == (&LarkOutbox.send/1)
    assert outbox_adapter.reconcile_fun == (&LarkOutbox.reconcile/1)
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

    assert {:ok, %OutboxAdapter{} = mock} =
             Adapters.fetch_outbox("mock-provider", registry)

    assert OutboxAdapter.capabilities(mock) ==
             MapSet.new([:post_entry, :reply_entry, :outbound_reconciliation])
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

    assert {:ok, %Definition{id: "inbound-only", outbox_adapter: nil}} =
             Adapters.fetch("inbound-only", registry)

    assert {:error, {:signal_adapter_outbox_unavailable, "inbound-only"}} =
             Adapters.fetch_outbox("inbound-only", registry)
  end

  test "rejects string-key outbox callback results" do
    adapter = %OutboxAdapter{
      capabilities: MapSet.new([:post_entry]),
      send_fun: fn _outbox -> {:ok, %{"created_source_entry_id" => "provider-id"}} end,
      reconcile_fun: nil
    }

    assert {:error, {:invalid_adapter_result_key, "created_source_entry_id"}} =
             OutboxAdapter.deliver(adapter, %{})
  end

  test "rejects string-key reply preview callback results" do
    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{"created_source_entry_id" => "provider-id"}} end,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end,
      refresh_fun: nil
    }

    request = %ReplyPreviewAdapter.Request{
      actor_event: %Ankole.SignalsGateway.ActorEvent{},
      presentation: %{},
      mode: :working
    }

    assert {:error, {:invalid_reply_preview_adapter_result_key, "created_source_entry_id"}} =
             ReplyPreviewAdapter.open(adapter, request)
  end

  test "filters only exact runtime secret values before outbox delivery" do
    %{principal: agent} = agent_fixture()

    {worker_auth_key, worker_env_secret, visible_env_value} =
      configure_runtime_secrets!(agent.uid)

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
      "fabric #{worker_auth_key}; custom #{worker_env_secret}; " <>
        "visible #{visible_env_value}; jwt #{jwt}; #{bearer}; #{assignment}\n#{private_key}\n" <>
        "the #{short_secret} deployment"

    parent = self()

    adapter = %OutboxAdapter{
      capabilities: MapSet.new([:post_entry]),
      send_fun: fn outbox ->
        send(parent, {:filtered_outbox, outbox})
        {:ok, %{}}
      end,
      reconcile_fun: nil
    }

    outbox = %OutboxEntry{
      agent_uid: agent.uid,
      payload: %{"text" => text, "nested" => [text]},
      fallback_visible_text: text
    }

    assert {:ok, %{}} = OutboxAdapter.deliver(adapter, outbox)
    assert_receive {:filtered_outbox, %OutboxEntry{} = filtered}

    rendered = inspect(filtered)
    refute rendered =~ worker_auth_key
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

    {worker_auth_key, worker_env_secret, _visible_env_value} =
      configure_runtime_secrets!(agent.uid)

    parent = self()

    adapter = %ReplyPreviewAdapter{
      open_fun: fn request ->
        send(parent, {:filtered_preview, request})
        {:ok, %{}}
      end,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end,
      refresh_fun: nil
    }

    request = %ReplyPreviewAdapter.Request{
      actor_event: %ActorEvent{
        agent_uid: agent.uid,
        reply_preview_checkpoint: %{"presentation" => %{"answer" => worker_auth_key}}
      },
      presentation: %{"answer" => "answer #{worker_auth_key} #{worker_env_secret}"},
      previous_presentation: %{"answer" => worker_auth_key},
      checkpoint: %{"presentation" => %{"answer" => worker_env_secret}},
      outbox: %OutboxEntry{
        agent_uid: agent.uid,
        payload: %{"text" => worker_auth_key},
        fallback_visible_text: worker_env_secret
      },
      mode: :working
    }

    assert {:ok, %{}} = ReplyPreviewAdapter.open(adapter, request)
    assert_receive {:filtered_preview, filtered}

    rendered = inspect(filtered)
    refute rendered =~ worker_auth_key
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
    worker_auth_key = "fabric-runtime-value-#{System.unique_integer([:positive])}"
    worker_env_secret = "custom-runtime-value-#{System.unique_integer([:positive])}"
    visible_env_value = "visible-runtime-value-#{System.unique_integer([:positive])}"

    assert {:ok, ^worker_auth_key} =
             AppConfigure.put_global(WorkerAuthKey.definition(), worker_auth_key)

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

    {worker_auth_key, worker_env_secret, visible_env_value}
  end
end
