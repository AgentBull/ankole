defmodule Ankole.SignalsGateway.AdaptersTest do
  use Ankole.DataCase, async: false

  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.LarkAdapter.Outbox, as: LarkOutbox
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.OutboxAdapter

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
    def api_version, do: 1

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
    def api_version, do: 1

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

  test "resolves mock and string-key declarations through the same interface" do
    registry = start_registry!([MockSignalProviderPlugin, StringKeyPlugin])

    assert {:ok, %OutboxAdapter{} = mock} =
             Adapters.fetch_outbox("mock-provider", registry)

    assert OutboxAdapter.capabilities(mock) ==
             MapSet.new([:post_entry, :reply_entry, :outbound_reconciliation])

    assert {:ok,
            %Definition{
              id: "string-key",
              display_name: %{"default" => "String Key Adapter"}
            }} = Adapters.fetch("string-key", registry)

    assert {:ok, %OutboxAdapter{} = string_key} =
             Adapters.fetch_outbox("string-key", registry)

    assert OutboxAdapter.capabilities(string_key) == MapSet.new([:post_entry])
    assert string_key.send_fun == (&StringKeyOutbox.send/1)
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

  defp start_registry!(modules) do
    name = :"signal_adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, name: name, discovery: [paths: [], modules: modules]},
      id: name
    )

    name
  end
end
