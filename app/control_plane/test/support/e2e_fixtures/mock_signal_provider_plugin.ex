defmodule Ankole.PluginFixtures.MockSignalProviderPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.PluginFixtures.MockSignalProvider.Inbound
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview

  @impl true
  def plugin_id, do: "mock-signal-provider"

  @impl true
  def display_name, do: %{"default" => "Mock Signal Provider"}

  # `mock-provider` is a plain-text provider; `mock-rich-provider` also declares
  # a reply-preview module, so a gateway test can cover the mutable reply
  # surface and its terminal outbox route in-process.
  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "mock-provider",
        adapter_category: "enterprise_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Mock Signal Provider"},
        ingress_module: Inbound,
        outbox_module: Outbox,
        inbound_capabilities: ["entry_receive"],
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "outbound_reconciliation"
        ]
      },
      %{
        contract_id: "signals_gateway.adapter",
        id: "mock-rich-provider",
        adapter_category: "enterprise_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Mock Rich Signal Provider"},
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: ReplyPreview,
        inbound_capabilities: ["entry_receive"],
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "outbound_reconciliation"
        ]
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MockSignalProvider.ReplyPreview do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @recipient_key {__MODULE__, :recipient}
  @finalize_result_key {__MODULE__, :finalize_result}

  @doc false
  def put_recipient(pid) when is_pid(pid), do: :persistent_term.put(@recipient_key, pid)

  @doc false
  def delete_recipient, do: :persistent_term.erase(@recipient_key)

  @doc false
  def put_finalize_result(result), do: :persistent_term.put(@finalize_result_key, result)

  @doc false
  def delete_finalize_result, do: :persistent_term.erase(@finalize_result_key)

  @impl true
  def open(%Request{} = request), do: sync(:open, request, "open")

  @impl true
  def update(%Request{} = request), do: sync(:update, request, "open")

  @impl true
  def finalize(%Request{} = request) do
    notify(:finalize, request)

    case :persistent_term.get(@finalize_result_key, :checkpoint) do
      :checkpoint -> checkpoint(request, "closed")
      result -> result
    end
  end

  @impl true
  def refresh(%Request{} = request),
    do: sync(:refresh, request, request.checkpoint["streaming_state"] || "open")

  @impl true
  def surface_ids(checkpoint) when is_map(checkpoint) do
    checkpoint
    |> Map.get("messages", [])
    |> Enum.map(& &1["message_id"])
    |> Kernel.++([checkpoint["message_id"]])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.map(&{:entry, &1})
  end

  @impl true
  def surface_open?(checkpoint) when is_map(checkpoint),
    do: checkpoint["streaming_state"] != "closed"

  defp sync(kind, request, streaming_state) do
    notify(kind, request)
    checkpoint(request, streaming_state)
  end

  defp notify(kind, request) do
    case :persistent_term.get(@recipient_key, nil) do
      pid when is_pid(pid) -> send(pid, {:mock_provider_preview, kind, request})
      _value -> :ok
    end
  end

  defp checkpoint(%Request{actor_event: event} = request, streaming_state) do
    message_id = "mock-preview-#{event.id}"

    checkpoint =
      request.checkpoint
      |> Map.merge(%{
        "schema_version" => 1,
        "adapter" => "mock-rich-provider",
        "message_id" => message_id,
        "messages" => [%{"index" => 0, "message_id" => message_id}],
        "presentation" => ReplyPresentation.checkpoint(request.presentation),
        "streaming_state" => streaming_state
      })
      |> put_text("subject_uid", request.subject_uid)
      |> put_text("conversation_id", request.conversation_id)
      |> Map.delete("refresh_pending")
      |> Map.delete("refresh_reason")

    with :ok <- Actors.record_reply_preview_source_entry(event.id, message_id),
         {:ok, event} <- Actors.put_reply_preview_checkpoint(event.id, checkpoint) do
      {:ok,
       %{
         created_source_entry_id: message_id,
         reply_preview_checkpoint: event.reply_preview_checkpoint,
         raw_payload: %{"provider" => "mock-signal-provider"}
       }}
    end
  end

  defp put_text(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_text(map, _key, _value), do: map
end

defmodule Ankole.PluginFixtures.MockSignalProvider.Inbound do
  @moduledoc false

  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Ingress

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

    Ingress.emit_entry(context.agent_uid, context.binding_name, entry_input(event), options)
  end

  defp emit_receive(_consumer, _event), do: {:error, :invalid_mock_consumer}

  defp entry_input(event) do
    event_id = fetch(event, :source_event_id) || "mock-event-#{unique_id()}"
    channel_id = fetch(event, :signal_channel_id) || "mock:chat:e2e"
    source_entry_id = fetch(event, :source_entry_id) || "mock-message-#{unique_id()}"
    provider_thread_id = fetch(event, :provider_thread_id) || "mock-thread"
    text = fetch(event, :text) || "PING"

    %{
      source_event_id: event_id,
      signal_channel_id: channel_id,
      source_entry_id: source_entry_id,
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
      raw_payload: %{"event_id" => event_id, "source_entry_id" => source_entry_id},
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
  @send_result_key {__MODULE__, :send_result}
  @reconcile_result_key {__MODULE__, :reconcile_result}

  @doc false
  def put_recipient(pid) when is_pid(pid), do: :persistent_term.put(@recipient_key, pid)

  @doc false
  def delete_recipient, do: :persistent_term.erase(@recipient_key)

  @doc false
  def put_send_result(result), do: :persistent_term.put(@send_result_key, result)

  @doc false
  def delete_send_result, do: :persistent_term.erase(@send_result_key)

  @doc false
  def put_reconcile_result(result), do: :persistent_term.put(@reconcile_result_key, result)

  @doc false
  def delete_reconcile_result, do: :persistent_term.erase(@reconcile_result_key)

  @impl true
  def send(outbox) do
    case :persistent_term.get(@recipient_key, nil) do
      pid when is_pid(pid) -> Kernel.send(pid, {:mock_provider_outbox_sent, outbox})
      _value -> :ok
    end

    :persistent_term.get(
      @send_result_key,
      {:ok,
       %{
         created_source_entry_id: "mock-reply-#{System.unique_integer([:positive])}",
         raw_payload: %{"provider" => "mock-signal-provider"}
       }}
    )
  end

  @impl true
  def reconcile(_outbox), do: :persistent_term.get(@reconcile_result_key, :unknown)
end
