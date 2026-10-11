defmodule Ankole.Plugins.SlackAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled Slack bindings and identity providers into Socket Mode
  connections. Bindings and identity providers of one app share one connection.
  """

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "slack",
    registry: Ankole.Plugins.SlackAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.SlackAdapter.ConnectionDynamicSupervisor

  alias Ankole.SignalsGateway.Bindings
  alias Ankole.Plugins.SlackAdapter.{Config, Dispatcher, IdentityProvider, Inbound}
  alias Ankole.SignalsGateway.{AdapterContext, Binding}

  @impl true
  def binding_spec(%Binding{} = binding, _opts) do
    case Bindings.binding_config(binding, Config) do
      {:ok, config} ->
        context =
          AdapterContext.new(
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            adapter: binding.adapter,
            user_name: Map.get(config, "userName", "Slack")
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
    %{
      id: {SlackOpenAPI.SocketMode.Client, key},
      start: {__MODULE__, :start_client, [key, config, consumers]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  def start_client(key, config, consumers) do
    with {:ok, resolved} <- Config.resolve_runtime_bot_identity(config) do
      client = Config.client(config)

      identity =
        Map.take(resolved, ["runtimeAppID", "runtimeBotUserID", "runtimeBotID", "runtimeTeamID"])

      runtime_consumers = Enum.map(consumers, &%{&1 | config: Map.merge(&1.config, identity)})

      via =
        {:via, Registry,
         {Ankole.Plugins.SlackAdapter.ConnectionRegistry, key,
          Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

      SlackOpenAPI.SocketMode.Client.start_link(
        client: client,
        dispatcher: Dispatcher.build(runtime_consumers, client: client),
        expected_app_id: Map.fetch!(resolved, "runtimeAppID"),
        name: via
      )
    else
      {:error, reason} -> {:error, {:runtime_bot_identity, reason}}
    end
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
      get_in(config, ["sync", "websocket"]) != false and
      is_binary(Map.get(config, "appToken"))
  end
end
