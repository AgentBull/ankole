defmodule Ankole.SignalsGateway.ReplyPreviewAdapter do
  @moduledoc """
  Provider-neutral lifecycle contract for one mutable AI reply surface.

  SignalsGateway owns the semantic presentation and its PostgreSQL checkpoint;
  adapters own only the provider handle and provider-native mutations. This
  keeps Slack Block Kit and Lark CardKit data out of worker events while each
  adapter implements its own transport rules.

  Before each provider call, SignalsGateway reloads the owning ActorEvent,
  takes the checkpoint from that row, and resolves the binding configuration.
  An implementation therefore reads `request.actor_event`, `request.checkpoint`,
  and `request.config` and never queries those facts itself.

  The checkpoint keys that name provider surfaces belong to the adapter. The
  host asks `surface_ids/1` which provider ids the checkpoint holds and
  `surface_open?/1` whether that surface still accepts updates; it never reads
  provider vocabulary itself. An `{:entry, id}` names a provider entry that
  humans see: the host can delete it and matches inbound callbacks against it.
  A `{:handle, id}` names a provider object only the adapter operates on.

  A lifecycle call can answer `{:error, {:degraded, :plain_text, detail}}`.
  That result says the surface cannot show the presentation and the durable
  outbox must deliver plain text instead; the host stops the preview and does
  not retry the call.
  """

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.OutboundSecretFilter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Utils

  @checkpoint_schema_version 2
  @adapter_state_key "adapter_state"
  @host_checkpoint_keys ~w(
    cleanup_at
    closed_at
    continued_to_actor_event_id
    conversation_id
    interactions
    opened_at
    owner_generation
    presentation
    presentation_owner
    previous_presentation
    recovery_state
    refresh_pending
    refresh_reason
    schema_version
    sequence_high_water
    stream_actor_event_id
    stream_deadline_at
    streaming_state
    subject_uid
  )

  defmodule Request do
    @moduledoc """
    One provider-neutral reply surface operation.

    `actor_event` names the owning ActorEvent; the gateway reloads that row and
    fills `checkpoint`, `previous_presentation`, `subject_uid`,
    `conversation_id`, and `config` before the adapter runs.
    `previous_presentation` is the presentation that the checkpoint last
    confirmed, or `nil` before the first confirmed sync. `config` is the stored
    binding configuration, or `nil` when the binding has none.
    """

    @enforce_keys [:actor_event, :presentation, :mode]
    @derive {Inspect, except: [:config]}
    defstruct [
      :actor_event,
      :presentation,
      :previous_presentation,
      :checkpoint,
      :subject_uid,
      :conversation_id,
      :outbox,
      :config,
      :mode
    ]

    @type t :: %__MODULE__{
            actor_event: ActorEvent.t(),
            presentation: map(),
            previous_presentation: map() | nil,
            checkpoint: map() | nil,
            subject_uid: String.t() | nil,
            conversation_id: String.t() | nil,
            outbox: OutboxEntry.t() | nil,
            config: map() | nil,
            mode: :working | :terminal
          }
  end

  @enforce_keys [:open_fun, :update_fun, :finalize_fun, :surface_ids_fun, :surface_open_fun]
  defstruct [
    :open_fun,
    :update_fun,
    :finalize_fun,
    :refresh_fun,
    :surface_ids_fun,
    :surface_open_fun
  ]

  @type adapter_result :: {:ok, map()} | {:error, term()}
  @type finalize_result :: adapter_result() | :unknown
  @type degraded_result :: {:error, {:degraded, :plain_text, term()}}
  @type surface_id :: {:entry, String.t()} | {:handle, String.t()}
  @type t :: %__MODULE__{
          open_fun: (Request.t() -> term()),
          update_fun: (Request.t() -> term()),
          finalize_fun: (Request.t() -> term()),
          refresh_fun: (Request.t() -> term()) | nil,
          surface_ids_fun: (map() -> [surface_id()]),
          surface_open_fun: (map() -> boolean())
        }

  @callback open(Request.t()) :: adapter_result() | degraded_result() | term()
  @callback update(Request.t()) :: adapter_result() | degraded_result() | term()
  @callback finalize(Request.t()) :: finalize_result() | degraded_result() | term()
  @callback refresh(Request.t()) :: adapter_result() | degraded_result() | term()
  @callback surface_ids(checkpoint :: map()) :: [surface_id()]
  @callback surface_open?(checkpoint :: map()) :: boolean()
  @optional_callbacks refresh: 1

  @spec from_module(module()) :: {:ok, t()} | {:error, term()}
  def from_module(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module) || {:error, :invalid_reply_preview_adapter},
         :ok <- Utils.validate_module_callback(module, :open, 1),
         :ok <- Utils.validate_module_callback(module, :update, 1),
         :ok <- Utils.validate_module_callback(module, :finalize, 1),
         :ok <- Utils.validate_module_callback(module, :surface_ids, 1),
         :ok <- Utils.validate_module_callback(module, :surface_open?, 1) do
      {:ok,
       %__MODULE__{
         open_fun: Function.capture(module, :open, 1),
         update_fun: Function.capture(module, :update, 1),
         finalize_fun: Function.capture(module, :finalize, 1),
         refresh_fun:
           if(function_exported?(module, :refresh, 1),
             do: Function.capture(module, :refresh, 1),
             else: nil
           ),
         surface_ids_fun: Function.capture(module, :surface_ids, 1),
         surface_open_fun: Function.capture(module, :surface_open?, 1)
       }}
    end
  end

  def from_module(_module), do: {:error, :invalid_reply_preview_adapter}

  @doc """
  Resolves the reply-preview adapter that the event's binding declares.
  """
  @spec for_event(ActorEvent.t()) :: t() | nil
  def for_event(%ActorEvent{agent_uid: agent_uid, binding_name: binding_name}) do
    case Bindings.get_binding(agent_uid, binding_name) do
      {:ok, %Binding{} = binding} -> for_binding(binding)
      {:error, _reason} -> nil
    end
  end

  @spec for_binding(Binding.t()) :: t() | nil
  def for_binding(%Binding{adapter: adapter_id}) do
    case Adapters.fetch_reply_preview(adapter_id) do
      {:ok, %__MODULE__{} = adapter} -> adapter
      {:error, _reason} -> nil
    end
  end

  @doc """
  Lists the provider ids that the checkpoint holds for its reply surface.
  """
  @spec surface_ids(t() | nil, map() | nil) :: [surface_id()]
  def surface_ids(%__MODULE__{surface_ids_fun: fun}, checkpoint) when is_map(checkpoint),
    do: fun.(adapter_checkpoint(checkpoint))

  def surface_ids(_adapter, _checkpoint), do: []

  @spec surface_entry_ids(t() | nil, map() | nil) :: [String.t()]
  def surface_entry_ids(adapter, checkpoint) do
    for {:entry, id} <- surface_ids(adapter, checkpoint), do: id
  end

  @doc """
  Returns whether the checkpoint holds a provider surface at all.
  """
  @spec surface?(t() | nil, map() | nil) :: boolean()
  def surface?(adapter, checkpoint), do: surface_ids(adapter, checkpoint) != []

  @doc """
  Returns whether the provider surface still accepts updates.
  """
  @spec surface_open?(t() | nil, map() | nil) :: boolean()
  def surface_open?(%__MODULE__{surface_open_fun: fun}, checkpoint) when is_map(checkpoint),
    do: fun.(adapter_checkpoint(checkpoint))

  def surface_open?(_adapter, _checkpoint), do: false

  @doc """
  Returns the logical checkpoint that a reply-preview implementation reads.

  Version 2 keeps host fields at the top level and provider fields under
  `adapter_state`. A flat version 1 row is already in the logical form. Host
  fields win if a malformed nested row repeats one of them.
  """
  @spec adapter_checkpoint(map() | nil) :: map()
  def adapter_checkpoint(checkpoint) when is_map(checkpoint) do
    host = Map.delete(checkpoint, @adapter_state_key)

    case checkpoint[@adapter_state_key] do
      adapter_state when is_map(adapter_state) -> Map.merge(adapter_state, host)
      _legacy_or_invalid -> host
    end
  end

  def adapter_checkpoint(_checkpoint), do: %{}

  @doc false
  @spec persisted_checkpoint(map()) :: map()
  def persisted_checkpoint(checkpoint) when is_map(checkpoint) do
    checkpoint = adapter_checkpoint(checkpoint)

    checkpoint
    |> Map.take(@host_checkpoint_keys)
    |> Map.put("schema_version", @checkpoint_schema_version)
    |> Map.put(
      @adapter_state_key,
      Map.drop(checkpoint, [@adapter_state_key | @host_checkpoint_keys])
    )
  end

  @spec open(t(), Request.t()) :: adapter_result()
  def open(%__MODULE__{open_fun: fun}, %Request{} = request),
    do: fun |> call_adapter(request) |> normalize_result()

  @spec update(t(), Request.t()) :: adapter_result()
  def update(%__MODULE__{update_fun: fun}, %Request{} = request),
    do: fun |> call_adapter(request) |> normalize_result()

  @doc """
  Delivers the terminal presentation through the provider surface.

  `:unknown` means the adapter sent something but cannot confirm that it
  landed; the durable outbox turns it into `unknown_after_send`.
  """
  @spec finalize(t(), Request.t()) :: finalize_result()
  def finalize(%__MODULE__{finalize_fun: fun}, %Request{} = request) do
    case call_adapter(fun, request) do
      :unknown -> :unknown
      result -> normalize_result(result)
    end
  end

  @doc """
  Finalizes one durable AI reply row through the declared preview module.

  The row carries the terminal presentation and names the owning ActorEvent;
  every other request field comes from that ActorEvent when the call runs.
  """
  @spec finalize_outbox(t(), OutboxEntry.t()) :: finalize_result()
  def finalize_outbox(
        %__MODULE__{} = adapter,
        %OutboxEntry{
          payload: %{"reply_presentation" => presentation},
          source_actor_event_id: actor_event_id
        } = outbox
      )
      when is_map(presentation) and is_binary(actor_event_id) do
    finalize(adapter, %Request{
      actor_event: %ActorEvent{id: actor_event_id},
      presentation: presentation,
      outbox: outbox,
      mode: :terminal
    })
  end

  @spec refresh(t(), Request.t()) :: adapter_result()
  def refresh(%__MODULE__{refresh_fun: fun}, %Request{} = request) when is_function(fun, 1),
    do: fun |> call_adapter(request) |> normalize_result()

  def refresh(%__MODULE__{refresh_fun: nil}, %Request{}),
    do: {:error, :reply_preview_refresh_unsupported}

  defp call_adapter(fun, request) do
    with {:ok, request} <- complete_request(request),
         {:ok, filtered_request} <- OutboundSecretFilter.filter_reply_preview(request) do
      fun.(filtered_request)
    end
  end

  defp complete_request(%Request{actor_event: %ActorEvent{id: actor_event_id}} = request)
       when is_binary(actor_event_id) do
    with %ActorEvent{} = event <- Repo.get(ActorEvent, actor_event_id) || :actor_event_not_found,
         {:ok, binding} <- Bindings.get_binding(event.agent_uid, event.binding_name),
         {:ok, config} <- stored_config(binding) do
      checkpoint = adapter_checkpoint(event.reply_preview_checkpoint)

      {:ok,
       %{
         request
         | actor_event: event,
           checkpoint: checkpoint,
           previous_presentation: checkpoint["presentation"],
           subject_uid: request.subject_uid || checkpoint["subject_uid"],
           conversation_id: request.conversation_id || checkpoint["conversation_id"],
           config: config
       }}
    else
      :actor_event_not_found -> {:error, :actor_event_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp complete_request(%Request{}), do: {:error, :actor_event_not_found}

  # A binding without stored configuration hands `nil` to the adapter, whose
  # own validation rejects it; a key that no plugin declares has no stored
  # value either. A store failure stops the call here.
  defp stored_config(binding) do
    case Bindings.stored_binding_config(binding) do
      {:ok, config} -> {:ok, config}
      {:error, :binding_config_unavailable} -> {:ok, nil}
      {:error, {:unknown_key, _key}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_result({:ok, result}) when is_map(result) do
    case Enum.find(Map.keys(result), &(not is_atom(&1))) do
      nil -> {:ok, result}
      key -> {:error, {:invalid_reply_preview_adapter_result_key, Sanitizer.transport(key)}}
    end
  end

  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(result) do
    {:error, {:invalid_reply_preview_adapter_result, Sanitizer.transport(result)}}
  end
end
