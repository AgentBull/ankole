defmodule Ankole.Conversations.Delivery.PreviewAdapter do
  @moduledoc """
  Provider-neutral lifecycle contract for one mutable AI reply surface.

  Conversations.Delivery owns the semantic presentation and its PostgreSQL checkpoint;
  adapters own only the provider handle and provider-native mutations. This
  keeps Slack Block Kit and Lark CardKit data out of worker events while each
  adapter implements its own transport rules.

  Before each provider call, Conversations.Delivery reloads the owning Signal,
  takes the checkpoint from that row, and resolves the binding configuration.
  An implementation therefore reads `request.signal`, `request.checkpoint`,
  and `request.config` and never queries those facts itself.

  The checkpoint keys that name provider surfaces belong to the adapter. The
  host asks `surface_ids/1` which provider ids the checkpoint holds and
  `surface_open?/1` whether that surface still accepts updates; it never reads
  provider vocabulary itself. An `{:entry, id}` names a provider entry that
  humans see: the host can delete it and matches inbound callbacks against it.
  A `{:handle, id}` names a provider object only the adapter operates on.

  A lifecycle call can answer `{:error, {:degraded, :plain_text, detail}}`.
  That result says the surface cannot show the presentation and the durable
  intent must deliver plain text instead; the host stops the preview and does
  not retry the call.
  """

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Signals.Signal
  alias Ankole.Signals.Adapters
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Conversations.Delivery.SecretFilter
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Signals.Sanitizer

  @checkpoint_schema_version 2
  @adapter_state_key "adapter_state"
  @host_checkpoint_keys ~w(
    cleanup_at
    closed_at
    continued_to_signal_id
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
    stream_signal_id
    stream_deadline_at
    streaming_state
    subject_uid
  )

  defmodule Request do
    @moduledoc """
    One provider-neutral reply surface operation.

    `signal` names the owning Signal; the gateway reloads that row and
    fills `checkpoint`, `previous_presentation`, `subject_uid`,
    `conversation_id`, and `config` before the adapter runs.
    `previous_presentation` is the presentation that the checkpoint last
    confirmed, or `nil` before the first confirmed sync. `config` is the stored
    binding configuration, or `nil` when the binding has none.
    """

    @enforce_keys [:signal, :presentation, :mode]
    @derive {Inspect, except: [:config]}
    defstruct [
      :signal,
      :presentation,
      :previous_presentation,
      :checkpoint,
      :subject_uid,
      :conversation_id,
      :delivery,
      :config,
      :mode
    ]

    @type t :: %__MODULE__{
            signal: Signal.t(),
            presentation: map(),
            previous_presentation: map() | nil,
            checkpoint: map() | nil,
            subject_uid: String.t() | nil,
            conversation_id: String.t() | nil,
            delivery: Intent.t() | nil,
            config: map() | nil,
            mode: :working | :terminal
          }
  end

  @enforce_keys [:update_fun, :finalize_fun, :surface_ids_fun, :surface_open_fun]
  defstruct [
    :update_fun,
    :finalize_fun,
    :refresh_fun,
    :surface_ids_fun,
    :surface_open_fun
  ]

  @type adapter_result :: {:ok, map()} | {:error, term()}
  @type finalize_result :: adapter_result() | :unknown | {:unknown, map()}
  @type degraded_result :: {:error, {:degraded, :plain_text, term()}}
  @type surface_id :: {:entry, String.t()} | {:handle, String.t()}
  @type t :: %__MODULE__{
          update_fun: (Request.t() -> term()),
          finalize_fun: (Request.t() -> term()),
          refresh_fun: (Request.t() -> term()) | nil,
          surface_ids_fun: (map() -> [surface_id()]),
          surface_open_fun: (map() -> boolean())
        }

  @callback update(Request.t()) :: adapter_result() | degraded_result() | term()
  @callback finalize(Request.t()) :: finalize_result() | degraded_result() | term()
  @callback refresh(Request.t()) :: adapter_result() | degraded_result() | term()
  @callback surface_ids(checkpoint :: map()) :: [surface_id()]
  @callback surface_open?(checkpoint :: map()) :: boolean()
  @optional_callbacks refresh: 1

  @spec from_module(module()) :: {:ok, t()} | {:error, term()}
  def from_module(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module) || {:error, :invalid_preview_adapter},
         :ok <- Ankole.Attrs.validate_module_callback(module, :update, 1),
         :ok <- Ankole.Attrs.validate_module_callback(module, :finalize, 1),
         :ok <- Ankole.Attrs.validate_module_callback(module, :surface_ids, 1),
         :ok <- Ankole.Attrs.validate_module_callback(module, :surface_open?, 1) do
      {:ok,
       %__MODULE__{
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

  def from_module(_module), do: {:error, :invalid_preview_adapter}

  @doc """
  Resolves the reply-preview adapter that the event's binding declares.
  """
  @spec for_event(Signal.t()) :: t() | nil
  def for_event(%Signal{reply_binding_id: id})
      when is_binary(id) do
    case Bindings.get_binding(id) do
      {:ok, %Binding{} = binding} -> for_binding(binding)
      {:error, _reason} -> nil
    end
  end

  def for_event(%Signal{}), do: nil

  @spec for_binding(Binding.t()) :: t() | nil
  def for_binding(%Binding{adapter: adapter_id}) do
    case Adapters.fetch_preview(adapter_id) do
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

  @doc "Sets the cleanup deadline for a preview that can still show transient thought."
  @spec put_thought_lease(map(), map(), boolean(), pos_integer()) :: map()
  def put_thought_lease(checkpoint, presentation, final?, lease_seconds) do
    if not final? and is_binary(presentation["thought"]) and presentation["thought"] != "" do
      deadline =
        DateTime.utc_now(:microsecond)
        |> DateTime.add(lease_seconds, :second)
        |> DateTime.to_iso8601()

      Map.put(checkpoint, "cleanup_at", deadline)
    else
      Map.delete(checkpoint, "cleanup_at")
    end
  end

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

  @spec update(t(), Request.t()) :: adapter_result()
  def update(%__MODULE__{update_fun: fun}, %Request{} = request),
    do: fun |> call_adapter(request) |> normalize_result()

  @doc """
  Delivers the terminal presentation through the provider surface.

  `:unknown` means the adapter sent something but cannot confirm that it
  landed; the durable intent turns it into `unknown_after_send`.
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

  The row carries the terminal presentation and names the owning Signal;
  every other request field comes from that Signal when the call runs.
  """
  @spec finalize_intent(t(), Intent.t()) :: finalize_result()
  def finalize_intent(
        %__MODULE__{} = adapter,
        %Intent{
          payload: %{"reply_presentation" => presentation},
          source_signal_id: signal_id
        } = intent
      )
      when is_map(presentation) and is_binary(signal_id) do
    finalize(adapter, %Request{
      signal: %Signal{id: signal_id},
      presentation: presentation,
      delivery: intent,
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
         {:ok, filtered_request} <- SecretFilter.filter_reply_preview(request) do
      fun.(filtered_request)
    end
  end

  defp complete_request(%Request{signal: %Signal{id: signal_id}} = request)
       when is_binary(signal_id) do
    with %Signal{} = event <- PreviewStates.load_signal(signal_id) || :signal_not_found,
         {:ok, binding} <- Bindings.get_binding(event.reply_binding_id),
         {:ok, config} <- stored_config(binding) do
      checkpoint =
        adapter_checkpoint(PreviewStates.get(event).checkpoint)

      {:ok,
       %{
         request
         | signal: event,
           checkpoint: checkpoint,
           previous_presentation: checkpoint["presentation"],
           subject_uid: request.subject_uid || checkpoint["subject_uid"],
           conversation_id: request.conversation_id || checkpoint["conversation_id"],
           config: config
       }}
    else
      :signal_not_found -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp complete_request(%Request{}), do: {:error, :signal_not_found}

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
      key -> {:error, {:invalid_preview_adapter_result_key, Sanitizer.transport(key)}}
    end
  end

  defp normalize_result({:unknown, %{} = detail}), do: {:unknown, detail}

  defp normalize_result({:error, reason}), do: {:error, reason}

  defp normalize_result(result) do
    {:error, {:invalid_preview_adapter_result, Sanitizer.transport(result)}}
  end
end
