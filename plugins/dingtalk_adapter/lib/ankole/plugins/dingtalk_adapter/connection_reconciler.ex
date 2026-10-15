defmodule Ankole.Plugins.DingTalkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled DingTalk bindings and identity providers into Stream
  connections. Bindings and identity providers of one app share one connection,
  so chat and login use one Stream socket.
  """

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "dingtalk",
    registry: Ankole.Plugins.DingTalkAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.DingTalkAdapter.ConnectionDynamicSupervisor

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.Dispatcher
  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding

  @impl true
  def binding_spec(%Binding{} = binding, _opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        context =
          AdapterContext.new(
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: Map.get(config, "userName", "钉钉 / DingTalk")
          )

        {:ok, connection_spec(config, Inbound.chat_consumer(context, config))}

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
       {Ankole.Plugins.DingTalkAdapter.ConnectionRegistry, key,
        Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

    %{
      id: {DingTalkOpenAPI.Stream.Client, key},
      start:
        {DingTalkOpenAPI.Stream.Client, :start_link,
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
