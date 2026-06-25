defmodule Ankole.AIAgent.LlmProviders do
  @moduledoc """
  CRUD and projection service for operator-configured LLM providers.

  A provider row holds an endpoint plus an encrypted credential. Plaintext
  credentials only ever leave through `plaintext_credential/1` (for the broker)
  and the live-check path; every console/API shape goes through `projection/1`,
  which masks the secret. "Deleting" a provider is a soft disable that is refused
  while any agent model profile still references it.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.LlmProviders.Crypto
  alias Ankole.AIAgent.LlmProviders.Provider
  alias Ankole.AIAgent.ProviderSources
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  # Sentinel distinguishing "caller did not mention the credential" (preserve it)
  # from "caller passed nil/blank" (clear it). A plain nil cannot express that
  # difference, so writes use this marker as the default.
  @credential_omitted :__ankole_credential_omitted__
  # Operator live-checks hit a third-party endpoint; cap both connect and read so
  # a slow or hanging provider cannot stall the Console request.
  @live_check_timeout_ms 15_000

  @type provider_result :: {:ok, Provider.t()} | {:error, term()}

  @doc """
  Lists available first-party provider sources.
  """
  @spec list_provider_sources() :: [map()]
  def list_provider_sources do
    Enum.map(ProviderSources.all(), &ProviderSources.projection/1)
  end

  @doc """
  Lists configured provider projections without plaintext credentials.
  """
  @spec list_providers() :: [map()]
  def list_providers do
    Provider
    |> order_by([provider], asc: provider.provider_id)
    |> Repo.all()
    |> Enum.map(&projection/1)
  end

  @doc """
  Fetches a provider row.
  """
  @spec fetch_provider(String.t()) :: provider_result()
  def fetch_provider(provider_id) when is_binary(provider_id) do
    case Repo.get(Provider, normalize_id(provider_id)) do
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
      with {:ok, attrs} <- provider_attrs_for_write(attrs, nil) do
        %Provider{}
        |> Provider.changeset(attrs)
        |> repo.insert()
      end
    end)
  end

  @doc """
  Updates provider metadata and optionally its credential.

  Credential write semantics:

  - omitted: preserve existing credential
  - `nil` or blank: clear credential
  - non-empty string: replace credential
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
    with {:ok, attrs} <- provider_attrs_for_write(attrs, nil) do
      %Provider{}
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
  provider credential just long enough to call the provider's model-list
  endpoint, then returns a redacted result suitable for Console/API display.
  """
  @spec live_check_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def live_check_provider(provider_id, opts \\ [])

  def live_check_provider(provider_id, opts) when is_binary(provider_id) do
    http_client = Keyword.get(opts, :http_client, &http_get/3)
    timeout_ms = Keyword.get(opts, :timeout_ms, @live_check_timeout_ms)

    with {:ok, %Provider{} = provider} <- fetch_active_provider(provider_id),
         {:ok, credential} <- plaintext_credential(provider),
         {:ok, connection} <- runtime_connection(provider),
         {:ok, request} <- live_check_request(provider.provider_source, connection, credential),
         {:ok, result} <- http_client.(request.url, request.headers, timeout_ms) do
      {:ok,
       Map.merge(result, %{
         "provider_id" => provider.provider_id,
         "provider_source" => provider.provider_source,
         "checked_at" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
         "endpoint" => request.endpoint
       })}
    end
  end

  def live_check_provider(_provider_id, _opts), do: {:error, :not_found}

  @doc """
  Decrypts a provider credential for the credential broker.
  """
  @spec plaintext_credential(Provider.t()) :: {:ok, String.t()} | {:error, term()}
  def plaintext_credential(%Provider{encrypted_credential: encrypted, provider_id: provider_id})
      when is_binary(encrypted) do
    Crypto.unseal(encrypted, provider_id)
  end

  def plaintext_credential(%Provider{}), do: {:error, :credential_missing}

  @doc """
  Returns a worker-safe connection config for one provider.
  """
  @spec runtime_connection(Provider.t()) :: {:ok, map()} | {:error, term()}
  def runtime_connection(%Provider{} = provider) do
    with {:ok, source} <- ProviderSources.fetch(provider.provider_source),
         {:ok, options} <-
           ProviderSources.normalize_connection_options(
             provider.provider_source,
             provider.connection_options || %{}
           ) do
      base_url =
        provider.base_url ||
          Map.get(options, "base_url") ||
          source.default_base_url

      {:ok,
       options
       |> Map.delete("base_url")
       |> Map.put("base_url", base_url)}
    end
  end

  @doc """
  Projects one provider without plaintext secrets.
  """
  @spec projection(Provider.t()) :: map()
  def projection(%Provider{} = provider) do
    source =
      case ProviderSources.fetch(provider.provider_source) do
        {:ok, source} -> ProviderSources.projection(source)
        {:error, _reason} -> %{}
      end

    %{
      "provider_id" => provider.provider_id,
      "provider_source" => provider.provider_source,
      "base_url" => provider.base_url,
      "connection_options" => provider.connection_options || %{},
      "credential_mode" => provider.credential_mode,
      "disabled_at" => provider.disabled_at && DateTime.to_iso8601(provider.disabled_at),
      "credential" => %{
        "present" => is_binary(provider.encrypted_credential),
        "masked" => credential_mask(provider.encrypted_credential)
      },
      "source_metadata" => %{
        "codex_compatible" => source["codex_compatible"],
        "adapter_strategy" => source["adapter_strategy"]
      }
    }
  end

  defp provider_attrs_for_write(attrs, provider) do
    attrs = normalize_external_attrs(attrs)
    provider_id = Map.get(attrs, "provider_id") || provider_id(provider)
    credential = Map.get(attrs, "credential", @credential_omitted)

    attrs =
      attrs
      |> Map.delete("credential")
      |> maybe_preserve_credential(provider)

    with {:ok, attrs} <- apply_credential(attrs, provider_id, credential),
         {:ok, attrs} <- normalize_connection_options(attrs, provider) do
      {:ok, attrs}
    end
  end

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_preserve_credential(attrs, %Provider{encrypted_credential: encrypted})
       when is_binary(encrypted),
       do: Map.put_new(attrs, "encrypted_credential", encrypted)

  defp maybe_preserve_credential(attrs, _provider), do: attrs

  defp apply_credential(attrs, _provider_id, @credential_omitted), do: {:ok, attrs}

  defp apply_credential(attrs, _provider_id, credential) when credential in [nil, ""],
    do: {:ok, Map.put(attrs, "encrypted_credential", nil)}

  defp apply_credential(attrs, provider_id, credential) when is_binary(credential) do
    case String.trim(credential) do
      "" ->
        {:ok, Map.put(attrs, "encrypted_credential", nil)}

      credential ->
        with provider_id when is_binary(provider_id) and provider_id != "" <- provider_id,
             {:ok, encrypted} <- Crypto.seal(credential, normalize_id(provider_id)) do
          {:ok, Map.put(attrs, "encrypted_credential", encrypted)}
        else
          nil -> {:error, :provider_id_required_for_credential}
          "" -> {:error, :provider_id_required_for_credential}
          {:error, _reason} = error -> error
        end
    end
  end

  defp apply_credential(_attrs, _provider_id, _credential), do: {:error, :invalid_credential}

  defp normalize_connection_options(attrs, provider) do
    source = Map.get(attrs, "provider_source") || provider_source(provider)
    options = Map.get(attrs, "connection_options") || connection_options(provider)

    with {:ok, normalized} <- ProviderSources.normalize_connection_options(source, options || %{}) do
      {:ok, Map.put(attrs, "connection_options", normalized)}
    end
  end

  defp lock_provider(repo, provider_id) do
    Provider
    |> where([provider], provider.provider_id == ^normalize_id(provider_id))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Finds every agent model profile still pointing at this provider, returned as
  # "agent_uid:profile" labels. A non-empty list blocks the disable so an
  # operator cannot silently break agents that depend on the provider; profiles
  # live inside each agent's `options` JSON, so this scans agents rather than a
  # dedicated join table.
  defp provider_references(repo, provider_id) do
    Agent
    |> select([agent], {agent.uid, agent.options})
    |> repo.all()
    |> Enum.flat_map(fn {agent_uid, options} ->
      options
      |> get_in(["ai_agent", "models"])
      |> profile_references(agent_uid, provider_id)
    end)
    |> Enum.sort()
  end

  defp profile_references(models, agent_uid, provider_id) when is_map(models) do
    for {profile, %{"provider_id" => ^provider_id}} <- models do
      "#{agent_uid}:#{profile}"
    end
  end

  defp profile_references(_models, _agent_uid, _provider_id), do: []

  defp provider_id(%Provider{provider_id: provider_id}), do: provider_id
  defp provider_id(_provider), do: nil

  defp provider_source(%Provider{provider_source: source}), do: source
  defp provider_source(_provider), do: nil

  defp connection_options(%Provider{connection_options: options}), do: options
  defp connection_options(_provider), do: %{}

  defp live_check_request(source, connection, credential)
       when source in ["openrouter", "openai"] do
    {:ok,
     %{
       url: endpoint_url(connection, "models"),
       endpoint: "/models",
       headers: connection_headers(connection) ++ [{"authorization", "Bearer #{credential}"}]
     }}
  end

  defp live_check_request("claude", connection, credential) do
    {:ok,
     %{
       url: endpoint_url(connection, "models"),
       endpoint: "/models",
       headers:
         connection_headers(connection) ++
           [{"x-api-key", credential}, {"anthropic-version", "2023-06-01"}]
     }}
  end

  defp live_check_request("gemini", connection, credential) do
    {:ok,
     %{
       url: endpoint_url(connection, "models"),
       endpoint: "/models",
       headers: connection_headers(connection) ++ [{"x-goog-api-key", credential}]
     }}
  end

  defp live_check_request(_source, _connection, _credential),
    do: {:error, :unsupported_provider_source}

  defp endpoint_url(connection, path) do
    base_url =
      connection
      |> Map.fetch!("base_url")
      |> String.trim_trailing("/")

    "#{base_url}/#{path}"
  end

  defp connection_headers(connection) do
    connection
    |> Map.get("headers", %{})
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp http_get(url, headers, timeout_ms) do
    :ok = ensure_http_started()

    request = {String.to_charlist(url), charlist_headers(headers)}
    http_options = [timeout: timeout_ms, connect_timeout: timeout_ms]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, _body}} when status in 200..299 ->
        {:ok, %{"status" => "ok", "http_status" => status}}

      {:ok, {{_version, status, reason}, _response_headers, body}} ->
        {:error,
         {:provider_live_check_failed,
          %{
            "http_status" => status,
            "reason" => to_string(reason),
            "body" => truncate_body(body)
          }}}

      {:error, reason} ->
        {:error, {:provider_live_check_failed, reason}}
    end
  end

  defp ensure_http_started do
    :ok = Application.ensure_started(:ssl)
    :ok = Application.ensure_started(:inets)
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 2_000)
  defp truncate_body(body), do: inspect(body)

  defp normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_id(value), do: value

  defp credential_mask(nil), do: nil
  defp credential_mask(_encrypted), do: "********"
end
