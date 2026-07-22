defmodule Ankole.SignalsGateway.AdaptersTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.OutboxAdapter
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

  defp start_registry!(modules) do
    name = :"signal_adapter_registry_#{System.unique_integer([:positive])}"

    assert {:ok, _enabled_ids} = Config.put_enabled_ids(Enum.map(modules, & &1.plugin_id()))

    start_supervised!(
      {Registry, name: name, modules: modules},
      id: name
    )

    name
  end
end
