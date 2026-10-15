defmodule Ankole.Plugins.LarkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled Lark bindings and identity providers into long
  connections. Bindings and identity providers of one app share one connection.
  A binding whose bot identity cannot be resolved blocks its connection key, so
  a live connection keeps its chat consumer until the identity resolves again.
  """

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "lark",
    registry: Ankole.Plugins.LarkAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Dispatcher
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding

  @impl true
  def binding_spec(%Binding{} = binding, opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        config =
          Config.resolve_runtime_bot_identity(config, Keyword.take(opts, [:bot_info_fetcher]))

        if is_binary(Map.get(config, "runtimeBotOpenID")) do
          context =
            AdapterContext.new(
              agent_uid: binding.agent_uid,
              binding_name: binding.name,
              adapter: binding.adapter,
              user_name: Map.get(config, "userName", "Lark / Feishu")
            )

          {:ok, connection_spec(config, Inbound.chat_consumer(context, config))}
        else
          {:blocked, Config.connection_key(config), :runtime_bot_identity_unavailable}
        end

      :error ->
        {:error, :chat_config_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def identity_spec(%{"provider_id" => provider_id, "config_key" => config_key}) do
    with {:ok, config} <- Config.load_identity_config_key(config_key),
         true <- realtime_identity_sync_enabled?(config) || :skip do
      {:ok, connection_spec(config, IdentityProvider.identity_consumer(provider_id, config))}
    else
      :skip -> :skip
      :error -> {:error, :identity_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def connection_key(config, _consumers), do: Config.connection_key(config)

  @impl true
  def owner_child_spec(key, config, consumers) do
    client = Config.client(config)

    via =
      {:via, Registry,
       {Ankole.Plugins.LarkAdapter.ConnectionRegistry, key,
        Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

    %{
      id: {FeishuOpenAPI.WS.Client, key},
      start:
        {FeishuOpenAPI.WS.Client, :start_link,
         [[client: client, dispatcher: Dispatcher.build(consumers, client: client), name: via]]},
      restart: :temporary,
      type: :worker
    }
  end

  defp connection_spec(config, consumer) do
    %{
      config: config,
      secret_fingerprint: Config.secret_fingerprint(config),
      consumers: [consumer]
    }
  end

  defp realtime_identity_sync_enabled?(config) do
    get_in(config, ["sync", "contacts"]) != false and
      get_in(config, ["sync", "websocket"]) != false
  end
end
