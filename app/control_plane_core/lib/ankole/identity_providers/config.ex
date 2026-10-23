defmodule Ankole.IdentityProviders.Config do
  @moduledoc """
  AppConfigure state for active identity-provider instances.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Codec
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema
  alias Ankole.IdentityProviders.DirectoryState
  alias Ankole.IdentityProviders.LocalPassword

  @active_key "principals.identity_providers.active"
  @directory_full_sync_interval_minutes_key "principals.identity_providers.directory_full_sync_interval_minutes"
  @default_directory_full_sync_interval_minutes 15
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
      scope: :tenant,
      key: @active_key,
      encrypted: false,
      schema: Schema.new(&validate_activations/1),
      default_value: [],
      # The identity provider pages own this list and write it through `save_provider/2`.
      # Hand-editing the raw activation list in the Console can strand an admin outside every
      # working login path.
      console_writable: false,
      description: "Identity provider instances available to admin authentication."
    )
  end

  @doc """
  Returns the periodic full-directory-sync interval definition.
  """
  @spec directory_full_sync_interval_minutes_definition() :: Definition.t()
  def directory_full_sync_interval_minutes_definition do
    AppConfigure.define(
      scope: :tenant,
      key: @directory_full_sync_interval_minutes_key,
      encrypted: false,
      schema: Schema.new(&validate_directory_full_sync_interval_minutes/1),
      default_value: @default_directory_full_sync_interval_minutes,
      description: "Minutes between periodic full directory sync enqueue attempts."
    )
  end

  @doc """
  Returns all AppConfigure definitions owned by identity providers.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: [active_definition(), directory_full_sync_interval_minutes_definition()]

  @doc """
  Returns the configured full-directory-sync interval in seconds.
  """
  @spec directory_full_sync_interval_seconds() :: {:ok, pos_integer()} | {:error, term()} | :error
  def directory_full_sync_interval_seconds do
    with {:ok, minutes} <- AppConfigure.get(directory_full_sync_interval_minutes_definition()) do
      {:ok, minutes * 60}
    end
  end

  @doc """
  Lists active-provider entries.
  """
  @spec active_providers() :: {:ok, [activation()]} | {:error, term()}
  def active_providers do
    AppConfigure.get(active_definition())
  end

  @doc """
  Stores a provider configuration and its activation in one transaction.
  """
  @spec save_provider(map(), map()) :: {:ok, map()} | {:error, term()}
  def save_provider(attrs, config) when is_map(attrs) and is_map(config) do
    with {:ok, next} <- validate_activation(attrs),
         {:ok, definition} <- Registry.require_key(next["config_key"]),
         {:ok, config} <- Codec.validate(definition, config),
         {:ok, adapter} <- Ankole.IdentityProviders.fetch_adapter(next["adapter_id"]),
         {:ok, module} <- Ankole.IdentityProviders.adapter_module(adapter),
         {:ok, application} <-
           Ankole.Signals.Bindings.resolve_platform_application(
             module,
             config,
             :identity_provider
           ),
         {:ok, {_activation_write, {persisted_config, _scope, _key}}} <-
           Ankole.Ash.run_action(DirectoryState, :save_configuration, %{
             activation: next,
             config: config,
             application: application
           }) do
      {:ok, persisted_config}
    end
  end

  @doc false
  def save_provider_in_tx(repo, next, config, application) do
    with :ok <-
           Ankole.Signals.Bindings.validate_platform_application_in_tx(repo, application),
         :ok <-
           Ankole.IdentityProviders.DirectoryAccess.configuration_changed_in_tx(
             repo,
             next["provider_id"]
           ),
         {:ok, activation_write} <-
           AppConfigure.update_tenant_in_tx(repo, active_definition(), fn providers ->
             providers |> upsert(next) |> validate_activations()
           end),
         {:ok, config_write} <-
           AppConfigure.put_tenant_by_key_in_tx(repo, next["config_key"], config),
         :ok <-
           Ankole.Signals.Bindings.record_platform_application_in_tx(
             repo,
             config_write,
             application
           ) do
      {:ok, {activation_write, config_write}}
    end
  end

  @doc false
  def publish_saved_configuration({activation_write, config_write}) do
    {:ok, _config} = AppConfigure.cache_committed_write(config_write)
    {:ok, _providers} = AppConfigure.cache_committed_write(activation_write)
    :ok
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
           :ok <- unique_provider_id(activation, seen),
           :ok <- unique_local_provider(activation, acc) do
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

  defp validate_directory_full_sync_interval_minutes(value) when is_integer(value) and value >= 1,
    do: {:ok, value}

  defp validate_directory_full_sync_interval_minutes(_value),
    do: {:error, {:invalid_integer, "directory_full_sync_interval_minutes", %{min: 1}}}

  defp validate_activation(attrs) when is_map(attrs) do
    with {:ok, provider_id} <- fetch_id(attrs, :provider_id),
         :ok <- tenant_source_id(provider_id),
         {:ok, adapter_id} <- fetch_id(attrs, :adapter_id),
         {:ok, plugin_id} <- fetch_id(attrs, :plugin_id),
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

  defp tenant_source_id(provider_id) do
    if Ankole.IdentityProviders.SiteSources.registered?(provider_id),
      do: {:error, :reserved_identity_provider_id},
      else: :ok
  end

  defp unique_provider_id(%{"provider_id" => provider_id}, seen) do
    case MapSet.member?(seen, provider_id) do
      true -> {:error, {:duplicate_provider_id, provider_id}}
      false -> :ok
    end
  end

  defp upsert(providers, %{"provider_id" => provider_id} = next) do
    Enum.reject(providers, &match?(%{"provider_id" => ^provider_id}, &1)) ++ [next]
  end

  # Local providers share one credential table and one retry policy.
  defp unique_local_provider(%{"adapter_id" => adapter_id}, providers) do
    if adapter_id == LocalPassword.adapter_id() do
      case Enum.find(providers, &(&1["adapter_id"] == adapter_id)) do
        nil -> :ok
        %{"provider_id" => existing_id} -> {:error, {:local_provider_exists, existing_id}}
      end
    else
      :ok
    end
  end

  defp fetch_id(attrs, key) do
    attrs
    |> fetch_value(Atom.to_string(key))
    |> normalize_id(key)
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
