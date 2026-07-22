defmodule Ankole.SignalsGateway.WebhookHandlersTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry
  alias Ankole.SignalsGateway.WebhookHandlers
  alias Ankole.SignalsGateway.WebhookHandlers.Definition

  defmodule EchoHandler do
    @moduledoc false

    def handle_webhook(%{kind: "validation"} = request) do
      {:ok,
       %{status: 200, body: request.query_params["validationToken"], content_type: "text/plain"}}
    end

    def handle_webhook(%{kind: "events"} = request) do
      send(self(), {:webhook_request, request})
      {:ok, %{status: 200, body: %{"handled" => request.instance_id}}}
    end

    def handle_webhook(%{kind: "broken"}), do: :not_a_response
  end

  defmodule EchoPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "echo-webhook-plugin"

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals_gateway.webhook_handler",
          id: "echo",
          plugin_id: plugin_id(),
          module: Ankole.SignalsGateway.WebhookHandlersTest.EchoHandler,
          kinds: ["events", "validation", "broken"]
        }
      ]
    end
  end

  defmodule MissingCallbackPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "missing-callback-webhook-plugin"

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals_gateway.webhook_handler",
          id: "missing-callback",
          plugin_id: plugin_id(),
          module: __MODULE__,
          kinds: ["events"]
        }
      ]
    end
  end

  defmodule EmptyKindsPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "empty-kinds-webhook-plugin"

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals_gateway.webhook_handler",
          id: "empty-kinds",
          plugin_id: plugin_id(),
          module: Ankole.SignalsGateway.WebhookHandlersTest.EchoHandler,
          kinds: []
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

  test "lists and fetches declared webhook handlers" do
    registry = start_registry!([EchoPlugin])

    assert {:ok, [%Definition{id: "echo", module: EchoHandler} = definition]} =
             WebhookHandlers.list(registry)

    assert definition.kinds == ["events", "validation", "broken"]
    assert {:ok, %Definition{id: "echo"}} = WebhookHandlers.fetch("echo", registry)

    assert {:error, {:webhook_handler_not_found, "missing"}} =
             WebhookHandlers.fetch("missing", registry)
  end

  test "dispatches declared kinds and enforces the kind whitelist" do
    registry = start_registry!([EchoPlugin])

    request = %{
      handler_id: "echo",
      instance_id: "instance-1",
      kind: "events",
      query_params: %{},
      body_params: %{"type" => "message"},
      headers: %{"authorization" => "Bearer x"}
    }

    assert {:ok, %{status: 200, body: %{"handled" => "instance-1"}}} =
             WebhookHandlers.dispatch(request, registry)

    assert_received {:webhook_request, %{body_params: %{"type" => "message"}}}

    assert {:ok, %{status: 200, body: "token-1", content_type: "text/plain"}} =
             WebhookHandlers.dispatch(
               %{request | kind: "validation", query_params: %{"validationToken" => "token-1"}},
               registry
             )

    assert {:error, {:webhook_kind_not_declared, "echo", "directory"}} =
             WebhookHandlers.dispatch(%{request | kind: "directory"}, registry)

    assert {:error, {:invalid_webhook_handler_result, "echo", :not_a_response}} =
             WebhookHandlers.dispatch(%{request | kind: "broken"}, registry)
  end

  test "registry boot rejects handlers without callbacks or kinds" do
    capture_log(fn ->
      assert {:error, {reason, _spec}} = start_registry(MissingCallbackPlugin)

      assert {:invalid_adapter_contract_declaration, "signals_gateway.webhook_handler",
              "missing-callback", _plugin, _module,
              {:missing_adapter_callback, MissingCallbackPlugin, :handle_webhook, 1}} = reason

      assert {:error, {reason, _spec}} = start_registry(EmptyKindsPlugin)

      assert {:invalid_adapter_contract_declaration, "signals_gateway.webhook_handler",
              "empty-kinds", _plugin, _module, {:invalid_webhook_handler_kinds, []}} = reason
    end)
  end

  test "missing registry is reported as unavailable" do
    missing = :"webhook_handler_registry_#{System.unique_integer([:positive])}"

    assert {:error, :webhook_handler_registry_unavailable} =
             WebhookHandlers.fetch("echo", missing)
  end

  defp start_registry!(modules) do
    name = :"webhook_handler_registry_#{System.unique_integer([:positive])}"

    assert {:ok, _enabled_ids} = Config.put_enabled_ids(Enum.map(modules, & &1.plugin_id()))

    start_supervised!(
      {Registry, name: name, modules: modules},
      id: name
    )

    name
  end

  defp start_registry(module) do
    name = :"webhook_handler_registry_#{System.unique_integer([:positive])}"

    assert {:ok, [_plugin_id]} = Config.put_enabled_ids([module.plugin_id()])

    start_supervised(
      {Registry, name: name, modules: [module]},
      id: name
    )
  end
end
