defmodule Ankole.PluginFixtures.MockSignalProviderPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.PluginFixtures.MockSignalProvider.Inbound
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox

  @impl true
  def plugin_id, do: "mock-signal-provider"

  @impl true
  def api_version, do: 1

  @impl true
  def display_name, do: "Mock Signal Provider"

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "mock-provider",
        plugin_id: plugin_id(),
        display_name: "Mock Signal Provider",
        ingress_module: Inbound,
        outbox_module: Outbox,
        inbound_capabilities: ["entry_receive"],
        outbound_capabilities: ["reply_entry"]
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MockSignalProvider.Inbound do
  @moduledoc false

  alias Ankole.SignalsGateway.AdapterContext

  @spec chat_consumer(AdapterContext.t(), map(), keyword()) :: map()
  def chat_consumer(%AdapterContext{} = context, config, opts \\ []) when is_map(config) do
    %{
      kind: :mock_signal_provider,
      context: context,
      config: config,
      default_now: Keyword.get(opts, :now)
    }
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def handle_message_receive(_event_type, event, consumers)
      when is_map(event) and is_list(consumers) do
    consumers
    |> Enum.map(&emit_receive(&1, event))
    |> collect_results()
  end

  def handle_message_receive(_event_type, _event, _consumers), do: {:error, :invalid_mock_event}

  defp emit_receive(%{context: %AdapterContext{} = context} = consumer, event) do
    options =
      case fetch(event, :now) || Map.get(consumer, :default_now) do
        %DateTime{} = now -> [now: now]
        _value -> []
      end

    AdapterContext.emit_entry(context, entry_input(event), options)
  end

  defp emit_receive(_consumer, _event), do: {:error, :invalid_mock_consumer}

  defp entry_input(event) do
    event_id = fetch(event, :ingress_event_id) || "mock-event-#{unique_id()}"
    channel_id = fetch(event, :signal_channel_id) || "mock:chat:e2e"
    provider_entry_id = fetch(event, :provider_entry_id) || "mock-message-#{unique_id()}"
    provider_thread_id = fetch(event, :provider_thread_id) || "mock-thread"
    text = fetch(event, :text) || "PING"

    %{
      ingress_event_id: event_id,
      signal_channel_id: channel_id,
      provider_entry_id: provider_entry_id,
      provider_thread_id: provider_thread_id,
      channel: %{
        kind: fetch(event, :channel_kind) || :im_group,
        reply_mode: fetch(event, :reply_mode) || :entry,
        name: fetch(event, :channel_name) || "Mock Ops",
        metadata: %{"provider" => "mock-signal-provider"},
        raw_payload: %{"channel_id" => channel_id}
      },
      text: text,
      explicit: fetch(event, :explicit) == true,
      author: author(event),
      metadata: %{"provider" => "mock-signal-provider"},
      raw_payload: %{"event_id" => event_id, "provider_entry_id" => provider_entry_id},
      provider_time: fetch(event, :provider_time)
    }
  end

  defp author(event) do
    %{
      principal_uid: fetch(event, :author_principal_uid) || "mock-human",
      id: fetch(event, :author_id) || "mock-user",
      display_name: fetch(event, :author_display_name) || "Mock User"
    }
  end

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.fetch!(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp collect_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, result}, {:ok, acc} -> {:cont, {:ok, [result | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp unique_id, do: System.unique_integer([:positive]) |> Integer.to_string()
end

defmodule Ankole.PluginFixtures.MockSignalProvider.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  @recipient_key {__MODULE__, :recipient}

  @impl true
  def capabilities, do: [:reply_entry]

  @doc false
  def put_recipient(pid) when is_pid(pid), do: Process.put(@recipient_key, pid)

  @impl true
  def send(outbox) do
    case Process.get(@recipient_key) do
      pid when is_pid(pid) -> Kernel.send(pid, {:mock_provider_outbox_sent, outbox})
      _value -> :ok
    end

    {:ok,
     %{
       provider_entry_id: "mock-reply-#{System.unique_integer([:positive])}",
       raw_payload: %{"provider" => "mock-signal-provider"}
     }}
  end
end
