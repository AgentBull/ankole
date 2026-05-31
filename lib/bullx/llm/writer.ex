defmodule BullX.LLM.Writer do
  @moduledoc """
  Mutates durable LLM provider rows and refreshes the provider catalog cache.

  Writes validate the ReqLLM adapter, encrypt API keys, and preserve the
  BullX-facing `provider_id` as an immutable logical name. Cache refresh happens
  after persistence, so callers can distinguish write failure from a persisted
  but temporarily stale read model.
  """

  alias BullX.LLM.{Catalog, Crypto, Provider, ProviderRegistry}

  @known_keys ~w(provider_id req_llm_provider base_url api_key encrypted_api_key provider_options)a
  @key_lookup @known_keys |> Map.new(&{Atom.to_string(&1), &1})

  @type cache_refresh_failure :: {:cache_refresh_failed, String.t(), term()}
  @type stale_write :: {:persisted_but_stale, cache_refresh_failure()}
  @type provider_write_result ::
          {:ok, Provider.t()} | {:ok, Provider.t(), stale_write()} | {:error, term()}

  @spec put_provider(map() | keyword()) :: provider_write_result()
  def put_provider(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, provider_id} <- fetch_provider_id(attrs),
         :ok <- validate_req_llm_provider(attrs) do
      case BullX.Repo.get_by(Provider, provider_id: provider_id) do
        nil -> insert_provider(attrs)
        %Provider{} = provider -> update_existing_provider(provider, attrs)
      end
    end
  end

  @spec update_provider(String.t(), map() | keyword()) :: provider_write_result()
  def update_provider(provider_id, attrs) when is_binary(provider_id) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_provider_id_unchanged(provider_id, attrs),
         :ok <- validate_req_llm_provider(attrs),
         {:ok, provider} <- get_provider(provider_id) do
      update_existing_provider(provider, attrs)
    end
  end

  @spec delete_provider(String.t()) :: :ok | {:ok, stale_write()} | {:error, term()}
  def delete_provider(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- get_provider(provider_id),
         {:ok, _provider} <- BullX.Repo.delete(provider) do
      stale_status_after_delete(provider_id)
    end
  end

  @spec refresh_provider(String.t()) :: :ok | {:error, cache_refresh_failure()}
  def refresh_provider(provider_id) when is_binary(provider_id) do
    case Catalog.Cache.refresh(provider_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cache_refresh_failed, provider_id, reason}}
    end
  end

  defp insert_provider(attrs) do
    provider = %Provider{id: BullX.Ext.gen_uuid_v7()}

    with {:ok, attrs} <- apply_api_key(attrs, provider.id),
         changeset <- Provider.changeset(provider, attrs),
         {:ok, validated_provider} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, _provider_options} <- validate_provider_options(validated_provider),
         {:ok, provider} <- BullX.Repo.insert(changeset) do
      stale_status_after_write(provider)
    end
  end

  defp update_existing_provider(%Provider{} = provider, attrs) do
    with {:ok, attrs} <- apply_api_key(attrs, provider.id),
         attrs <- Map.delete(attrs, :provider_id),
         changeset <- Provider.changeset(provider, attrs),
         {:ok, validated_provider} <- Ecto.Changeset.apply_action(changeset, :update),
         {:ok, _provider_options} <- validate_provider_options(validated_provider),
         {:ok, provider} <- BullX.Repo.update(changeset) do
      stale_status_after_write(provider)
    end
  end

  defp validate_provider_options(%Provider{} = provider) do
    Catalog.validate_provider_row_options(
      provider.req_llm_provider,
      provider.provider_id,
      provider.provider_options
    )
  end

  defp stale_status_after_write(%Provider{} = provider) do
    case refresh_provider(provider.provider_id) do
      :ok -> {:ok, provider}
      {:error, reason} -> {:ok, provider, {:persisted_but_stale, reason}}
    end
  end

  defp stale_status_after_delete(provider_id) do
    case refresh_provider(provider_id) do
      :ok -> :ok
      {:error, reason} -> {:ok, {:persisted_but_stale, reason}}
    end
  end

  defp get_provider(provider_id) do
    case BullX.Repo.get_by(Provider, provider_id: provider_id) do
      nil -> {:error, :not_found}
      %Provider{} = provider -> {:ok, provider}
    end
  end

  defp fetch_provider_id(%{provider_id: provider_id})
       when is_binary(provider_id) and provider_id != "",
       do: {:ok, provider_id}

  defp fetch_provider_id(_attrs), do: {:error, {:missing_field, :provider_id}}

  defp validate_provider_id_unchanged(provider_id, %{provider_id: provider_id}), do: :ok

  defp validate_provider_id_unchanged(_provider_id, attrs)
       when not is_map_key(attrs, :provider_id), do: :ok

  defp validate_provider_id_unchanged(provider_id, %{provider_id: new_provider_id}),
    do: {:error, {:provider_id_immutable, provider_id, new_provider_id}}

  defp validate_req_llm_provider(%{req_llm_provider: req_llm_provider})
       when is_binary(req_llm_provider) do
    case ProviderRegistry.known?(req_llm_provider) do
      true -> :ok
      false -> {:error, {:unknown_req_llm_provider, req_llm_provider}}
    end
  end

  defp validate_req_llm_provider(_attrs), do: :ok

  defp apply_api_key(attrs, row_id) do
    case Map.fetch(attrs, :api_key) do
      :error ->
        {:ok, attrs}

      {:ok, api_key} when api_key in [nil, ""] ->
        {:ok, attrs |> Map.put(:encrypted_api_key, nil) |> Map.delete(:api_key)}

      {:ok, api_key} when is_binary(api_key) ->
        with {:ok, encrypted_api_key} <- Crypto.encrypt_api_key(api_key, row_id) do
          {:ok, attrs |> Map.put(:encrypted_api_key, encrypted_api_key) |> Map.delete(:api_key)}
        end

      {:ok, _api_key} ->
        {:error, {:invalid_api_key, :must_be_string}}
    end
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()

  defp normalize_attrs(%{} = attrs) do
    Map.new(attrs, fn {key, value} ->
      normalized_key = normalize_key(key)
      {normalized_key, normalize_value(normalized_key, value)}
    end)
  end

  defp normalize_key(key) when is_atom(key) and key in @known_keys, do: key
  defp normalize_key(key) when is_binary(key), do: Map.get(@key_lookup, key, key)
  defp normalize_key(key), do: key

  defp normalize_value(:base_url, ""), do: nil
  defp normalize_value(:provider_options, nil), do: %{}
  defp normalize_value(_key, value), do: value
end
