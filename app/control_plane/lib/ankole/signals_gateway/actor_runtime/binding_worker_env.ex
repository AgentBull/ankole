defmodule Ankole.SignalsGateway.ActorRuntime.BindingWorkerEnv do
  @moduledoc """
  Resolves provider-derived shell variables from an Agent's signal bindings.

  Available bindings owned by active adapters are runtime contracts. A route
  binding selects its adapter identity. A disabled or unavailable route closes
  its adapter instead of selecting a different identity. An adapter with one
  available binding remains implicit for executions with no known Signal route.
  Residual bindings from disabled plugins are ignored.
  """

  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings

  @spec resolve(String.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def resolve(agent_uid, opts \\ []) when is_binary(agent_uid) do
    adapter_server = Keyword.get(opts, :adapter_server)

    with {:ok, bindings} <- Bindings.list_agent_bindings(agent_uid, opts) do
      bindings
      |> select_bindings(Keyword.get(opts, :binding_name))
      |> Enum.reduce_while({:ok, %{}}, &merge_binding(&1, &2, adapter_server))
    end
  end

  defp select_bindings(bindings, binding_name) do
    case Enum.find(bindings, &(&1.name == binding_name)) do
      %Binding{} = selected ->
        bindings
        |> Enum.filter(&available?/1)
        |> Enum.group_by(& &1.adapter)
        |> Enum.flat_map(fn
          {adapter, _adapter_bindings} when adapter == selected.adapter ->
            if available?(selected), do: [selected], else: []

          {_adapter, [binding]} ->
            [binding]

          {_adapter, _ambiguous} ->
            []
        end)
        |> Enum.sort_by(&{&1.adapter, &1.name})

      nil ->
        bindings
        |> Enum.filter(&available?/1)
        |> select_implicit_bindings()
    end
  end

  defp available?(%Binding{enabled: true, unavailable_reason: nil}), do: true
  defp available?(%Binding{}), do: false

  defp select_implicit_bindings(bindings) do
    bindings
    |> Enum.group_by(& &1.adapter)
    |> Enum.flat_map(fn
      {_adapter, [binding]} -> [binding]
      {_adapter, _ambiguous} -> []
    end)
    |> Enum.sort_by(&{&1.adapter, &1.name})
  end

  defp merge_binding(%Binding{} = binding, {:ok, acc}, adapter_server) do
    case fetch_adapter(binding.adapter, adapter_server) do
      {:ok, %Definition{worker_env_module: nil}} ->
        {:cont, {:ok, acc}}

      {:ok, %Definition{worker_env_module: module}} ->
        case module.resolve_worker_env(binding) do
          {:ok, vars} -> merge_vars(acc, vars)
          {:error, reason} -> fail_binding(binding, reason)
        end

      {:error, {:signal_adapter_not_found, adapter}} when adapter == binding.adapter ->
        {:cont, {:ok, acc}}

      {:error, reason} ->
        fail_binding(binding, reason)
    end
  end

  defp fetch_adapter(adapter, nil), do: Adapters.fetch(adapter)
  defp fetch_adapter(adapter, server), do: Adapters.fetch(adapter, server)

  defp merge_vars(acc, vars) when is_map(vars) do
    vars
    |> Enum.reduce_while({:ok, acc}, fn
      {name, value}, {:ok, merged} when is_binary(name) and is_binary(value) ->
        case Map.fetch(merged, name) do
          :error -> {:cont, {:ok, Map.put(merged, name, value)}}
          {:ok, ^value} -> {:cont, {:ok, merged}}
          {:ok, _other} -> {:halt, {:error, {:binding_worker_env_conflict, name}}}
        end

      entry, {:ok, _merged} ->
        {:halt, {:error, {:invalid_binding_worker_env, entry}}}
    end)
    |> case do
      {:ok, merged} -> {:cont, {:ok, merged}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp merge_vars(_acc, vars), do: {:halt, {:error, {:invalid_binding_worker_env, vars}}}

  defp fail_binding(binding, reason) do
    {:halt, {:error, {:binding_worker_env_unavailable, binding.adapter, binding.name, reason}}}
  end
end
