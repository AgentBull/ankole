defmodule Ankole.SignalsGateway.OutboxAdapter do
  @moduledoc """
  Normalized provider outbox adapter contract.

  Capability parsing is deliberately whitelist-based so provider input cannot
  create atoms.

  Real provider modules should declare `@behaviour #{inspect(__MODULE__)}` and
  implement `send/1`. `reconcile/1` is optional and is only used for recovery of
  a durable `sending` outbox row. Capabilities come from the plugin declaration.

  `send/1` receives provider operations only. A durable AI reply row whose
  adapter declares a reply-preview module never reaches `send/1`: SignalsGateway
  finalizes it through `reply_preview`.
  """

  alias Ankole.SignalsGateway.OutboundSecretFilter
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Utils

  # The closed universe of capabilities an adapter may advertise. The gateway
  # checks an operation against these before dispatching (e.g. `:reply` needs
  # `:reply_entry`). `:outbound_reconciliation` is the one that decides whether a
  # send interrupted mid-flight can be recovered vs. marked unknown.
  @capabilities MapSet.new([
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

  # Precomputed string→atom lookup so capabilities declared as strings (from
  # plugin manifests / JSON) resolve to the known atoms without ever calling
  # `String.to_atom` on external input.
  @capability_names Map.new(@capabilities, fn capability ->
                      {Atom.to_string(capability), capability}
                    end)

  @enforce_keys [:capabilities, :send_fun, :reconcile_fun]
  defstruct [:capabilities, :send_fun, :reconcile_fun, reply_preview: nil]

  @type adapter_result :: {:ok, map()} | {:error, term()} | :unknown

  @type t :: %__MODULE__{
          capabilities: MapSet.t(atom()),
          send_fun: nil | (term() -> term()),
          reconcile_fun: nil | (term() -> term()),
          reply_preview: ReplyPreviewAdapter.t() | nil
        }

  @callback send(term()) :: adapter_result() | term()
  @callback reconcile(term()) :: adapter_result() | term()

  @optional_callbacks reconcile: 1

  @doc """
  Constructs an executable adapter from its module and declared capabilities.

  Plugin declarations are the capability source of truth. The module contributes
  only the callbacks that execute the contract.
  """
  @spec from_module(module(), [atom() | String.t()] | MapSet.t(atom() | String.t())) ::
          {:ok, t()} | {:error, term()}
  def from_module(module, capabilities) when is_atom(module) do
    with true <- Code.ensure_loaded?(module) || {:error, :invalid_outbox_adapter},
         {:ok, capabilities} <- normalize_capabilities(capabilities),
         :ok <- Utils.validate_module_callback(module, :send, 1),
         :ok <- validate_reconcile_callback(module, capabilities) do
      {:ok,
       %__MODULE__{
         capabilities: capabilities,
         send_fun: module_fun(module, :send, 1),
         reconcile_fun: module_fun(module, :reconcile, 1)
       }}
    end
  end

  def from_module(_module, _capabilities), do: {:error, :invalid_outbox_adapter}

  @doc """
  Returns the normalized capability set.
  """
  @spec capabilities(t()) :: MapSet.t(atom())
  def capabilities(%__MODULE__{capabilities: capabilities}), do: capabilities

  @doc """
  Calls the adapter delivery function.
  """
  @spec deliver(t(), term()) :: adapter_result()
  def deliver(%__MODULE__{send_fun: send_fun}, outbox) when is_function(send_fun, 1) do
    with {:ok, filtered_outbox} <- OutboundSecretFilter.filter_outbox(outbox) do
      normalize_adapter_result(send_fun.(filtered_outbox))
    end
  end

  def deliver(%__MODULE__{}, _outbox), do: {:error, :adapter_send_missing}

  @doc """
  Calls the adapter reconciliation function.
  """
  @spec reconcile(t(), term()) :: adapter_result()
  def reconcile(%__MODULE__{reconcile_fun: reconcile_fun}, outbox)
      when is_function(reconcile_fun, 1) do
    with {:ok, filtered_outbox} <- OutboundSecretFilter.filter_outbox(outbox) do
      normalize_adapter_result(reconcile_fun.(filtered_outbox))
    end
  end

  def reconcile(%__MODULE__{}, _outbox), do: {:error, :adapter_reconcile_missing}

  # Coerce whatever the adapter returned into the three outcomes dispatch
  # understands. `:unknown` is a first-class result, not an error: it means the
  # adapter sent something but cannot confirm it landed, which the gateway turns
  # into `unknown_after_send`. A visible durable reply can retry within its
  # remaining attempt budget after the gateway adds a possible-duplicate notice;
  # other uncertain operations stop.
  # Any other shape is an adapter contract violation, sanitized before it is
  # stored in the error column.
  defp normalize_adapter_result({:ok, %{} = result}) do
    case Enum.find(Map.keys(result), &(not is_atom(&1))) do
      nil -> {:ok, result}
      key -> {:error, {:invalid_adapter_result_key, Sanitizer.transport(key)}}
    end
  end

  defp normalize_adapter_result({:error, reason}), do: {:error, reason}
  defp normalize_adapter_result(:unknown), do: :unknown

  defp normalize_adapter_result(result) do
    {:error, {:invalid_adapter_result, Sanitizer.transport(result)}}
  end

  defp module_fun(adapter, function, arity) do
    case function_exported?(adapter, function, arity) do
      true -> Function.capture(adapter, function, arity)
      false -> nil
    end
  end

  defp validate_reconcile_callback(module, capabilities) do
    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> Utils.validate_module_callback(module, :reconcile, 1)
      false -> :ok
    end
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&normalize_capability/1)
    |> Utils.collect_results()
    |> case do
      {:ok, values} -> {:ok, MapSet.new(values)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_capabilities(%MapSet{} = capabilities) do
    capabilities
    |> MapSet.to_list()
    |> normalize_capabilities()
  end

  defp normalize_capabilities(_capabilities), do: {:error, :invalid_outbox_adapter_capabilities}

  defp normalize_capability(capability) when is_atom(capability) do
    case MapSet.member?(@capabilities, capability) do
      true -> {:ok, capability}
      false -> {:error, {:unknown_outbox_capability, Atom.to_string(capability)}}
    end
  end

  defp normalize_capability(capability) when is_binary(capability) do
    case Map.fetch(@capability_names, capability) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:unknown_outbox_capability, capability}}
    end
  end

  defp normalize_capability(_capability), do: {:error, :invalid_outbox_adapter_capability}
end
