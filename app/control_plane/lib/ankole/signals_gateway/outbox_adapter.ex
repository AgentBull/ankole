defmodule Ankole.SignalsGateway.OutboxAdapter do
  @moduledoc """
  Normalized provider outbox adapter contract.

  The adapter can be a map used by tests or a module/runtime object. Capability
  parsing is deliberately whitelist-based so provider input cannot create atoms.

  Real provider modules should declare `@behaviour #{inspect(__MODULE__)}` and
  implement `capabilities/0` and `send/1`. `reconcile/1` is optional and is only
  used for recovery of a durable `sending` outbox row.
  """

  alias Ankole.SignalsGateway.Sanitizer

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

  @capability_names Map.new(@capabilities, fn capability ->
                      {Atom.to_string(capability), capability}
                    end)

  @enforce_keys [:capabilities, :send_fun, :reconcile_fun]
  defstruct [:capabilities, :send_fun, :reconcile_fun]

  @type adapter_result :: {:ok, map()} | {:error, term()} | :unknown

  @type t :: %__MODULE__{
          capabilities: MapSet.t(atom()),
          send_fun: nil | (term() -> term()),
          reconcile_fun: nil | (term() -> term())
        }

  @callback capabilities() :: [atom() | String.t()] | MapSet.t(atom() | String.t())
  @callback send(term()) :: adapter_result() | term()
  @callback reconcile(term()) :: adapter_result() | term()

  @optional_callbacks reconcile: 1

  @doc """
  Normalizes an adapter map or module into the outbox adapter contract.
  """
  @spec normalize(map() | module()) :: {:ok, t()} | {:error, term()}
  def normalize(adapter) when is_map(adapter) do
    with {:ok, capabilities} <- normalize_capabilities(fetch(adapter, :capabilities, [])) do
      {:ok,
       %__MODULE__{
         capabilities: capabilities,
         send_fun: fetch_fun(adapter, :send),
         reconcile_fun: fetch_fun(adapter, :reconcile)
       }}
    end
  end

  def normalize(adapter) when is_atom(adapter) do
    with true <- Code.ensure_loaded?(adapter) || {:error, :invalid_outbox_adapter},
         {:ok, capabilities} <- module_capabilities(adapter) do
      {:ok,
       %__MODULE__{
         capabilities: capabilities,
         send_fun: module_fun(adapter, :send, 1),
         reconcile_fun: module_fun(adapter, :reconcile, 1)
       }}
    end
  end

  def normalize(_adapter), do: {:error, :invalid_outbox_adapter}

  @doc """
  Returns the normalized capability set.
  """
  @spec capabilities(t()) :: MapSet.t(atom())
  def capabilities(%__MODULE__{capabilities: capabilities}), do: capabilities

  @doc """
  Calls the adapter delivery function.
  """
  @spec deliver(t(), term()) :: adapter_result()
  def deliver(%__MODULE__{send_fun: send_fun}, outbox) when is_function(send_fun, 1),
    do: normalize_adapter_result(send_fun.(outbox))

  def deliver(%__MODULE__{}, _outbox), do: {:error, :adapter_send_missing}

  @doc """
  Calls the adapter reconciliation function.
  """
  @spec reconcile(t(), term()) :: adapter_result()
  def reconcile(%__MODULE__{reconcile_fun: reconcile_fun}, outbox)
      when is_function(reconcile_fun, 1),
      do: normalize_adapter_result(reconcile_fun.(outbox))

  def reconcile(%__MODULE__{}, _outbox), do: {:error, :adapter_reconcile_missing}

  defp normalize_adapter_result({:ok, %{} = result}), do: {:ok, result}
  defp normalize_adapter_result({:error, reason}), do: {:error, reason}
  defp normalize_adapter_result(:unknown), do: :unknown

  defp normalize_adapter_result(result) do
    {:error, {:invalid_adapter_result, Sanitizer.transport(result)}}
  end

  defp module_capabilities(adapter) do
    case function_exported?(adapter, :capabilities, 0) do
      true -> normalize_capabilities(adapter.capabilities())
      false -> {:ok, MapSet.new()}
    end
  end

  defp module_fun(adapter, function, arity) do
    case function_exported?(adapter, function, arity) do
      true -> &apply(adapter, function, [&1])
      false -> nil
    end
  end

  defp normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&normalize_capability/1)
    |> collect_results()
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

  defp fetch(map, key, default) do
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.fetch!(map, Atom.to_string(key))
      true -> default
    end
  end

  defp fetch_fun(map, key) do
    case fetch(map, key, nil) do
      fun when is_function(fun, 1) -> fun
      _value -> nil
    end
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
