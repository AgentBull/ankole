defmodule Ankole.IdentityProviders.Config do
  @moduledoc """
  AppConfigure state for active identity-provider instances.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @active_key "principals.identity_providers.active"
  @id_pattern ~r/\A[a-z][a-z0-9_-]*\z/

  @type activation :: %{
          required(String.t()) => String.t() | boolean()
        }

  @doc """
  Returns the activation-list AppConfigure definition.
  """
  @spec active_definition() :: Definition.t()
  def active_definition do
    AppConfigure.define(
      key: @active_key,
      encrypted: false,
      schema: Schema.new(&validate_activations/1),
      default_value: [],
      description: "Identity provider instances available to admin authentication."
    )
  end

  @doc """
  Registers identity-provider AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([active_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @active_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists active-provider entries.
  """
  @spec active_providers() :: {:ok, [activation()]} | {:error, term()}
  def active_providers do
    with :ok <- ensure_registered(),
         {:ok, providers} <- AppConfigure.get(active_definition()) do
      {:ok, providers}
    end
  end

  @doc """
  Inserts or replaces one active-provider entry.
  """
  @spec upsert_active_provider(map()) :: {:ok, [activation()]} | {:error, term()}
  def upsert_active_provider(attrs) when is_map(attrs) do
    with {:ok, next} <- validate_activation(attrs),
         {:ok, providers} <- active_providers() do
      providers
      |> upsert(next)
      |> put_active_providers()
    end
  end

  @doc """
  Persists the whole active-provider list.
  """
  @spec put_active_providers([map()]) :: {:ok, [activation()]} | {:error, term()}
  def put_active_providers(providers) when is_list(providers) do
    with :ok <- ensure_registered() do
      AppConfigure.put_global(active_definition(), providers)
    end
  end

  @doc """
  Normalizes one provider id.
  """
  @spec normalize_provider_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_provider_id(value), do: normalize_id(value, :provider_id)

  defp validate_activations(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, MapSet.new(), []}, fn value, {:ok, seen, acc} ->
      with {:ok, activation} <- validate_activation(value),
           :ok <- unique_provider_id(activation, seen) do
        {:cont, {:ok, MapSet.put(seen, activation["provider_id"]), [activation | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen, activations} -> {:ok, Enum.reverse(activations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_activations(_values), do: {:error, :not_array}

  defp validate_activation(attrs) when is_map(attrs) do
    with {:ok, provider_id} <- fetch_id(attrs, "provider_id"),
         {:ok, adapter_id} <- fetch_id(attrs, "adapter_id"),
         {:ok, plugin_id} <- fetch_id(attrs, "plugin_id"),
         {:ok, config_key} <- fetch_non_empty_string(attrs, "config_key"),
         {:ok, enabled} <- fetch_enabled(attrs) do
      {:ok,
       %{
         "provider_id" => provider_id,
         "adapter_id" => adapter_id,
         "plugin_id" => plugin_id,
         "config_key" => config_key,
         "enabled" => enabled
       }}
    end
  end

  defp validate_activation(_attrs), do: {:error, :invalid_activation}

  defp unique_provider_id(%{"provider_id" => provider_id}, seen) do
    case MapSet.member?(seen, provider_id) do
      true -> {:error, {:duplicate_provider_id, provider_id}}
      false -> :ok
    end
  end

  defp upsert(providers, %{"provider_id" => provider_id} = next) do
    Enum.reject(providers, &match?(%{"provider_id" => ^provider_id}, &1)) ++ [next]
  end

  defp fetch_id(attrs, key) do
    attrs
    |> fetch_value(key)
    |> normalize_id(String.to_atom(key))
  end

  defp normalize_id(value, field) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Regex.match?(@id_pattern, normalized) do
      true -> {:ok, normalized}
      false -> {:error, {:invalid_id, field, value}}
    end
  end

  defp normalize_id(value, field), do: {:error, {:invalid_id, field, value}}

  defp fetch_non_empty_string(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      value ->
        {:error, {:missing, key, value}}
    end
  end

  defp fetch_enabled(attrs) do
    case fetch_value(attrs, "enabled") do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, true}
      value -> {:error, {:invalid_boolean, "enabled", value}}
    end
  end

  defp fetch_value(attrs, key) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, atom_key) -> Map.fetch!(attrs, atom_key)
      true -> nil
    end
  rescue
    ArgumentError ->
      Map.get(attrs, key)
  end
end
