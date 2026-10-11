defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Credentials do
  @moduledoc "Validates and encrypts the secret fields declared by a provider kind."

  alias Ankole.SecretKeyBase

  @purpose "worker_provider_credential"
  @table "worker_providers"

  def load(provider) do
    Enum.reduce_while(provider.credentials, {:ok, %{}}, fn {name, ciphertext}, {:ok, values} ->
      case SecretKeyBase.unseal(ciphertext, @purpose, [@table, provider.id, name]) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, name, value)}}
        {:error, _reason} -> {:halt, {:error, {:worker_provider_credential_unreadable, name}}}
      end
    end)
  end

  def prepare(provider, kind, definition, input) when is_map(input) do
    with :ok <- known_fields(input, definition.credentials),
         {:ok, previous} <- load(provider),
         {:ok, values} <- values(input, previous, definition.credentials),
         {:ok, values} <- prepare_kind(kind, provider, previous, values),
         {:ok, ciphertexts} <- encrypt(provider, values, previous) do
      {:ok, ciphertexts, values}
    end
  end

  def prepare(_provider, _kind, _definition, _input),
    do: {:error, {:invalid_worker_provider_credentials, "credentials must be a mapping"}}

  def validate(kind, definition, settings, secrets) do
    with :ok <- known_fields(secrets, definition.credentials),
         {:ok, _values} <- values(%{}, secrets, definition.credentials) do
      if function_exported?(kind, :validate_credentials, 2),
        do: kind.validate_credentials(settings, secrets),
        else: :ok
    end
  end

  defp prepare_kind(kind, provider, previous, values) do
    if function_exported?(kind, :prepare_credentials, 3),
      do: kind.prepare_credentials(provider, previous, values),
      else: {:ok, values}
  end

  defp known_fields(input, definition) do
    case Map.keys(input) -- Map.keys(definition) do
      [] -> :ok
      unknown -> {:error, {:unknown_worker_provider_credentials, unknown}}
    end
  end

  # An explicit nil removes the stored value. An empty or absent value keeps it.
  defp values(input, previous, definition) do
    Enum.reduce_while(definition, {:ok, %{}}, fn {name, rule}, {:ok, acc} ->
      value =
        case Map.fetch(input, name) do
          {:ok, nil} -> nil
          {:ok, value} when value != "" -> value
          _keep -> Map.get(previous, name)
        end

      cond do
        is_binary(value) and value != "" -> {:cont, {:ok, Map.put(acc, name, value)}}
        is_nil(value) and not rule.required -> {:cont, {:ok, acc}}
        true -> {:halt, {:error, {:invalid_worker_provider_credential, name}}}
      end
    end)
  end

  defp encrypt(provider, values, previous) do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      result =
        if previous[name] == value,
          do: {:ok, provider.credentials[name]},
          else: SecretKeyBase.seal(value, @purpose, [@table, provider.id, name])

      case result do
        {:ok, encrypted} -> {:cont, {:ok, Map.put(acc, name, encrypted)}}
        error -> {:halt, error}
      end
    end)
  end
end
