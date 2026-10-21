defmodule Ankole.Plugins.LarkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled Lark bindings and identity providers into long
  connections. Bindings and identity providers of one app share one connection.

  `binding_spec/2` only reads stored configuration. `owner_child_spec/3`
  resolves the bot identity through `Ankole.Plugins.LarkAdapter.BotIdentity`
  in the reconciler process, so the shared connection supervisor never waits
  on a provider call. A cached failure refuses the start without a provider
  call until the retry time; the reconcile result carries the reason and that
  time.
  """

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "lark",
    registry: Ankole.Plugins.LarkAdapter.ConnectionRegistry,
    supervisor: Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.LarkAdapter.BotIdentity
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Dispatcher
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
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
            user_name: Map.get(config, "userName", "Lark / Feishu")
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
    start =
      case resolve_chat_consumers(config, consumers) do
        {:ok, runtime_consumers} ->
          {__MODULE__, :start_client, [key, config, consumers, runtime_consumers]}

        {:error, failure} ->
          {__MODULE__, :refuse_start,
           [%{reason: BotIdentity.describe(failure), retry_at: failure.retry_at}]}
      end

    %{
      id: {FeishuOpenAPI.WS.Client, key},
      start: start,
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  def start_client(key, config, consumers, runtime_consumers) do
    client = Config.client(config)

    via =
      {:via, Registry,
       {Ankole.Plugins.LarkAdapter.ConnectionRegistry, key,
        Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

    FeishuOpenAPI.WS.Client.start_link(
      client: client,
      dispatcher: Dispatcher.build(runtime_consumers, client: client),
      name: via
    )
  end

  @doc false
  def refuse_start(reason), do: {:error, reason}

  # Only chat consumers need the bot identity. An identity-only connection
  # starts without a provider call.
  defp resolve_chat_consumers(config, consumers) do
    if Enum.any?(consumers, &match?(%{kind: :chat}, &1)) do
      with {:ok, open_id} <- BotIdentity.resolve(config) do
        {:ok,
         Enum.map(consumers, fn
           %{kind: :chat} = consumer ->
             %{consumer | config: Map.put(consumer.config, "runtimeBotOpenID", open_id)}

           consumer ->
             consumer
         end)}
      end
    else
      {:ok, consumers}
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
      get_in(config, ["sync", "websocket"]) != false
  end
end
