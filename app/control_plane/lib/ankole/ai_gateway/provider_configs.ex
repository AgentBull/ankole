defmodule Ankole.AIGateway.ProviderConfigs do
  @moduledoc """
  CRUD and projection service for operator-configured AIGateway providers.

  A provider row holds a provider kind, an endpoint override, plain connection
  options, and encrypted provider options. Plaintext encrypted options only
  leave through provider request construction and the live-check path; every
  console/API shape goes through `projection/1`, which masks encrypted values.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL

  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.Repo

  # Operator live-checks hit a third-party endpoint; cap both connect and read so
  # a slow or hanging provider cannot stall the Console request.
  @live_check_timeout_ms 15_000

  @typedoc """
  Common result shape for provider-row writes and fetches.
  """
  @type provider_result :: {:ok, Provider.t()} | {:error, term()}

  @doc """
  Lists available provider kinds.
  """
  @spec list_provider_kinds() :: [map()]
  def list_provider_kinds do
    Enum.map(Providers.all(), &Providers.projection/1)
  end

  @doc """
  Lists configured provider projections without plaintext encrypted options.
  """
  @spec list_providers() :: [map()]
  def list_providers do
    Provider
    |> order_by([provider], asc: provider.provider_id)
    |> Repo.all()
    |> Enum.map(&projection/1)
  end

  @doc """
  Lists active provider rows for runtime-facing catalogs.
  """
  @spec list_active_providers() :: [Provider.t()]
  def list_active_providers do
    Provider
    |> where([provider], is_nil(provider.disabled_at))
    |> order_by([provider], asc: provider.provider_id)
    |> Repo.all()
  end

  @doc """
  Fetches a provider row by its operator-facing provider id.
  """
  @spec fetch_provider(String.t()) :: provider_result()
  def fetch_provider(provider_id) when is_binary(provider_id) do
    case Repo.get_by(Provider, provider_id: normalize_id(provider_id)) do
      %Provider{} = provider -> {:ok, provider}
      nil -> {:error, :not_found}
    end
  end

  def fetch_provider(_provider_id), do: {:error, :not_found}

  @doc """
  Fetches an active provider row.
  """
  @spec fetch_active_provider(String.t()) :: provider_result()
  def fetch_active_provider(provider_id) do
    with {:ok, %Provider{} = provider} <- fetch_provider(provider_id) do
      case provider.disabled_at do
        nil -> {:ok, provider}
        %DateTime{} -> {:error, :provider_disabled}
      end
    end
  end

  @doc """
  Returns a safe projection for one provider.
  """
  @spec get_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def get_provider(provider_id) do
    with {:ok, provider} <- fetch_provider(provider_id) do
      {:ok, projection(provider)}
    end
  end

  @doc """
  Creates a provider row.
  """
  @spec create_provider(map()) :: provider_result()
  def create_provider(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      provider = %Provider{id: Ankole.Ecto.UUIDv7.autogenerate()}

      with {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
        provider
        |> Provider.changeset(attrs)
        |> repo.insert()
      end
    end)
  end

  @doc """
  Updates provider metadata and optionally its encrypted options.

  Encrypted option write semantics:

  - omitted: preserve existing encrypted option
  - `nil` or blank: clear that encrypted option
  - any other JSON-compatible value: replace that encrypted option
  """
  @spec update_provider(String.t(), map()) :: provider_result()
  def update_provider(provider_id, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with %Provider{} = provider <- lock_provider(repo, provider_id),
           {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
        provider
        |> Provider.changeset(attrs)
        |> repo.update()
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Disables a provider after checking active model-profile references.
  """
  @spec delete_provider(String.t()) :: provider_result()
  def delete_provider(provider_id) when is_binary(provider_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %Provider{} = provider <- lock_provider(repo, provider_id),
           [] <- provider_references(repo, provider.provider_id) do
        provider
        |> Provider.changeset(%{disabled_at: now})
        |> repo.update()
      else
        nil -> {:error, :not_found}
        references when is_list(references) -> {:error, {:provider_in_use, references}}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Validates provider attrs without writing them.
  """
  @spec validate_provider(map()) :: :ok | {:error, term()}
  def validate_provider(attrs) when is_map(attrs) do
    provider = %Provider{id: Ankole.Ecto.UUIDv7.autogenerate()}

    with {:ok, attrs} <- provider_attrs_for_write(attrs, provider) do
      provider
      |> Provider.changeset(attrs)
      |> case do
        %{valid?: true} -> :ok
        changeset -> {:error, changeset}
      end
    end
  end

  @doc """
  Performs an operator-triggered live provider check.

  This intentionally sits outside ordinary turn execution: it decrypts the
  encrypted provider options just long enough to call the provider's connection
  endpoint, then returns a redacted result suitable for Console/API display.
  """
  @spec live_check_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def live_check_provider(provider_id, opts \\ [])

  def live_check_provider(provider_id, opts) when is_binary(provider_id) do
    with {:ok, %Provider{} = provider} <- fetch_active_provider(provider_id),
         {:ok, _result} <- provider_connection_check(provider, opts) do
      {:ok,
       %{
         "status" => "ok",
         "provider_id" => provider.provider_id,
         "provider_kind" => provider.provider_kind,
         "checked_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
       }}
    else
      {:error, {:provider_connection_check_failed, status, body}} when is_integer(status) ->
        {:error,
         {:provider_live_check_failed,
          %{
            "http_status" => status,
            "reason" => "upstream_error",
            "body" => truncate_body(body)
          }}}

      {:error, :provider_connection_check_not_supported} = error ->
        error

      {:error, reason}
      when reason in [
             :provider_disabled,
             :missing_base_url,
             :unknown_ai_gateway_provider
           ] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:provider_live_check_failed, reason}}
    end
  end

  def live_check_provider(_provider_id, _opts), do: {:error, :not_found}

  @doc """
  Returns decrypted encrypted options for runtime request dispatch or live-checks.
  """
  @spec plaintext_encrypted_options(Provider.t()) :: {:ok, map()} | {:error, term()}
  def plaintext_encrypted_options(%Provider{id: id, encrypted_options: encrypted_options})
      when is_binary(id) and is_map(encrypted_options) do
    Enum.reduce_while(encrypted_options, {:ok, %{}}, fn
      {key, ciphertext}, {:ok, acc} when is_binary(key) and is_binary(ciphertext) ->
        case Crypto.unseal(ciphertext, id, key) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, reason} -> {:halt, {:error, {:encrypted_option_decrypt_failed, key, reason}}}
        end

      {key, _ciphertext}, {:ok, _acc} ->
        {:halt, {:error, {:invalid_encrypted_option, key}}}
    end)
  end

  def plaintext_encrypted_options(%Provider{}), do: {:ok, %{}}

  @doc """
  Returns a runtime-safe connection config for one provider.

  The provider row may omit `base_url` and `transport` when the provider
  implementation has safe defaults. The returned map is the single shape used by
  provider dispatch, live-checks, and model catalog projections.
  """
  @spec runtime_connection(Provider.t()) :: {:ok, map()} | {:error, term()}
  def runtime_connection(%Provider{} = provider) do
    with {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         {:ok, options} <-
           Providers.normalize_connection_options(
             provider.provider_kind,
             provider.connection_options || %{}
           ),
         {:ok, encrypted_options} <- plaintext_encrypted_options(provider),
         {:ok, base_url} <- runtime_base_url(provider, provider_kind) do
      {:ok,
       options
       |> Map.merge(encrypted_options)
       |> Map.put("base_url", base_url)}
    end
  end

  @doc """
  Projects one provider without plaintext secrets.
  """
  @spec projection(Provider.t()) :: map()
  def projection(%Provider{} = provider) do
    %{
      "id" => provider.id,
      "provider_id" => provider.provider_id,
      "provider_kind" => provider.provider_kind,
      "base_url" => provider.base_url,
      "connection_options" => provider.connection_options || %{},
      "encrypted_options" => encrypted_options_projection(provider),
      "disabled_at" => provider.disabled_at && DateTime.to_iso8601(provider.disabled_at),
      "provider_metadata" => provider_metadata(provider.provider_kind)
    }
  end

  # Write normalization happens before the changeset because encrypted option
  # handling depends on per-provider setting metadata.
  defp provider_attrs_for_write(attrs, %Provider{} = provider) do
    attrs = normalize_external_attrs(attrs)

    with :ok <- reject_credential_field(attrs),
         {:ok, attrs} <- reject_provider_id_change(attrs, provider),
         {:ok, attrs} <- normalize_connection_options(attrs, provider),
         {:ok, attrs} <- apply_encrypted_options(attrs, provider) do
      {:ok, attrs}
    end
  end

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # The old singular `credential` field is intentionally rejected. Credentials
  # are now ordinary provider options with encrypted storage metadata, so keeping
  # the old field would create two semantic centers for the same data.
  defp reject_credential_field(attrs) do
    case Map.has_key?(attrs, "credential") do
      true -> {:error, :credential_field_removed}
      false -> :ok
    end
  end

  defp reject_provider_id_change(attrs, %Provider{provider_id: nil}), do: {:ok, attrs}

  defp reject_provider_id_change(attrs, %Provider{provider_id: provider_id}) do
    case Map.get(attrs, "provider_id") do
      nil ->
        {:ok, attrs}

      value ->
        case normalize_id(value) do
          ^provider_id -> {:ok, Map.put(attrs, "provider_id", provider_id)}
          _value -> {:error, :provider_id_immutable}
        end
    end
  end

  # Only options declared as encrypted connection settings are sealed. Other
  # options remain in `connection_options`, which lets providers define arbitrary
  # JSON-compatible configuration without a hardcoded credential mode system.
  defp apply_encrypted_options(attrs, %Provider{id: row_id} = provider) when is_binary(row_id) do
    provider_kind = Map.get(attrs, "provider_kind") || provider_kind(provider)
    options = Map.get(attrs, "connection_options", %{})

    with {:ok, encrypted_keys} <- encrypted_option_keys(provider_kind),
         {:ok, encrypted_options} <-
           seal_encrypted_options(provider, row_id, options, encrypted_keys) do
      plain_options = Map.drop(options, encrypted_keys)

      {:ok,
       attrs
       |> Map.put("connection_options", plain_options)
       |> Map.put("encrypted_options", encrypted_options)}
    end
  end

  defp apply_encrypted_options(_attrs, _provider), do: {:error, :invalid_provider_id}

  defp normalize_connection_options(attrs, provider) do
    provider_kind = Map.get(attrs, "provider_kind") || provider_kind(provider)
    options = Map.get(attrs, "connection_options", connection_options(provider))

    with {:ok, normalized} <-
           Providers.normalize_connection_options(provider_kind, options || %{}) do
      {:ok, Map.put(attrs, "connection_options", normalized)}
    end
  end

  defp encrypted_option_keys(provider_kind) do
    with {:ok, definition} <- Providers.fetch(provider_kind) do
      keys =
        definition.settings
        |> Enum.filter(&(&1.encrypted? and &1.scope == :connection))
        |> Enum.map(&Atom.to_string(&1.key))

      {:ok, keys}
    end
  end

  # Omitted encrypted options are preserved during updates. Operators can clear
  # a stored secret explicitly with nil or an empty string, which avoids forcing
  # every edit form to resend secret values.
  defp seal_encrypted_options(provider, row_id, options, encrypted_keys) do
    Enum.reduce_while(encrypted_keys, {:ok, encrypted_options(provider)}, fn key, {:ok, acc} ->
      cond do
        not Map.has_key?(options, key) ->
          {:cont, {:ok, acc}}

        encrypted_option_clear?(Map.get(options, key)) ->
          {:cont, {:ok, Map.delete(acc, key)}}

        true ->
          case Crypto.seal(Map.fetch!(options, key), row_id, key) do
            {:ok, encrypted} -> {:cont, {:ok, Map.put(acc, key, encrypted)}}
            {:error, reason} -> {:halt, {:error, {:encrypted_option_seal_failed, key, reason}}}
          end
      end
    end)
  end

  defp encrypted_option_clear?(value), do: value in [nil, ""]

  defp runtime_base_url(%Provider{base_url: base_url}, _provider_kind)
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, %{base_url: base_url})
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, _provider_kind), do: {:error, :missing_base_url}

  defp lock_provider(repo, provider_id) do
    Provider
    |> where([provider], provider.provider_id == ^normalize_id(provider_id))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Finds every agent model profile still pointing at this provider, returned as
  # "agent_uid:profile" labels. A non-empty list blocks the disable so an
  # operator cannot silently break agents that depend on the provider; profiles
  # live inside each agent's `options` JSON, so the database filters and expands
  # only matching JSONB profile entries.
  defp provider_references(repo, provider_id) do
    %{rows: rows} =
      SQL.query!(
        repo,
        """
        SELECT agent.uid || ':' || profile.key AS reference
        FROM agents AS agent
        CROSS JOIN LATERAL jsonb_each(
          CASE
            WHEN jsonb_typeof(agent.options #> '{ai_agent,models}') = 'object'
              THEN agent.options #> '{ai_agent,models}'
            ELSE '{}'::jsonb
          END
        ) AS profile(key, value)
        WHERE jsonb_path_query_array(
          agent.options,
          'lax $.ai_agent.models.*.provider_id'::jsonpath
        ) @> jsonb_build_array($1::text)
          AND profile.value @> jsonb_build_object('provider_id', $1::text)
        ORDER BY reference
        """,
        [provider_id]
      )

    Enum.map(rows, fn [reference] -> reference end)
  end

  defp provider_kind(%Provider{provider_kind: provider_kind}), do: provider_kind
  defp provider_kind(_provider), do: nil

  defp connection_options(%Provider{connection_options: options}) when is_map(options),
    do: options

  defp connection_options(_provider), do: %{}

  defp encrypted_options(%Provider{encrypted_options: options}) when is_map(options),
    do: options

  defp encrypted_options(_provider), do: %{}

  # API projections expose presence only. The actual plaintext is only read for
  # runtime request preparation and live provider checks.
  defp encrypted_options_projection(%Provider{} = provider) do
    provider
    |> encrypted_options()
    |> Map.new(fn {key, value} ->
      {key, %{"present" => is_binary(value), "masked" => encrypted_option_mask(value)}}
    end)
  end

  # Provider metadata is attached to configured rows so Console can render the
  # accepted options and capabilities without querying the registry separately.
  defp provider_metadata(provider_kind) do
    case Providers.fetch(provider_kind) do
      {:ok, provider_kind} ->
        provider_kind
        |> Providers.projection()
        |> Map.take([
          "capabilities",
          "capability_specs",
          "settings"
        ])

      {:error, _reason} ->
        %{}
    end
  end

  # Connection checks are optional provider hooks, not model metadata sources.
  defp provider_connection_check(%Provider{} = provider, opts) do
    with {:ok, context} <- provider_connection_check_context(provider, opts),
         {:ok, definition} <- Providers.fetch(provider.provider_kind) do
      case function_exported?(definition.module, :check_connection, 1) do
        true -> apply(definition.module, :check_connection, [context])
        false -> {:error, :provider_connection_check_not_supported}
      end
    end
  end

  # The live-check context intentionally looks like a small prepare context but
  # keeps `http_client` injectable for tests and live-check diagnostics.
  defp provider_connection_check_context(%Provider{} = provider, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @live_check_timeout_ms)
    capability = Keyword.get(opts, :capability, "llm")

    with {:ok, connection} <- runtime_connection(provider) do
      {:ok,
       %{
         provider_id: provider.provider_id,
         provider_kind: provider.provider_kind,
         capability: capability,
         connection: connection,
         settings: atomize_keys(connection),
         timeout_ms: timeout_ms,
         http_client: Keyword.get(opts, :http_client)
       }}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp encrypted_option_mask(value) when is_binary(value), do: "********"
  defp encrypted_option_mask(_value), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 2_000)
  defp truncate_body(body), do: inspect(body)

  defp normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_id(value), do: value
end
