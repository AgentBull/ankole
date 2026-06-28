defmodule Ankole.AIGateway.ProviderConfigs do
  @moduledoc """
  CRUD and projection service for operator-configured AIGateway providers.

  A provider row holds a provider kind, an endpoint override, connection options,
  and an encrypted credential. Plaintext credentials only ever leave through
  `plaintext_credential/1` (for the broker) and the live-check path; every
  console/API shape goes through `projection/1`, which masks the secret.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.HttpProtocol
  alias Ankole.AIGateway.ProviderConfigs.Crypto
  alias Ankole.AIGateway.ProviderConfigs.Provider
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
  Lists available provider kinds.
  """
  @spec list_provider_kinds() :: [map()]
  def list_provider_kinds do
    Enum.map(Providers.all(), &Providers.projection/1)
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
  provider credential just long enough to call the provider's model-list
  endpoint, then returns a redacted result suitable for Console/API display.
  """
  @spec live_check_provider(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def live_check_provider(provider_id, opts \\ [])

  def live_check_provider(provider_id, opts) when is_binary(provider_id) do
    http_client = Keyword.get(opts, :http_client, &http_get/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, @live_check_timeout_ms)

    with {:ok, %Provider{} = provider} <- fetch_active_provider(provider_id),
         {:ok, credential} <- plaintext_credential(provider),
         {:ok, connection} <- runtime_connection(provider),
         {:ok, request} <- live_check_request(provider, connection, credential),
         request <- Map.put(request, :timeout_ms, timeout_ms),
         {:ok, result} <- call_live_check_client(http_client, request) do
      {:ok,
       Map.merge(result, %{
         "provider_id" => provider.provider_id,
         "provider_kind" => provider.provider_kind,
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
  def plaintext_credential(%Provider{id: id, encrypted_credential: encrypted})
      when is_binary(id) and is_binary(encrypted) do
    Crypto.unseal(encrypted, id)
  end

  def plaintext_credential(%Provider{}), do: {:error, :credential_missing}

  @doc """
  Returns a runtime-safe connection config for one provider.

  The provider row may omit `base_url` and `http_protocol` when the provider
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
         {:ok, base_url} <- runtime_base_url(provider, provider_kind) do
      http_protocol = Map.get(options, "http_protocol") || provider_kind.default_http_protocol

      connection =
        options
        |> Map.delete("http_protocol")
        |> Map.put("base_url", base_url)
        |> Map.put("http_protocol", http_protocol)

      {:ok, connection}
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
      "credential_mode" => provider.credential_mode,
      "disabled_at" => provider.disabled_at && DateTime.to_iso8601(provider.disabled_at),
      "credential" => %{
        "present" => is_binary(provider.encrypted_credential),
        "masked" => credential_mask(provider.encrypted_credential)
      },
      "provider_metadata" => provider_metadata(provider.provider_kind)
    }
  end

  # Write normalization happens before the changeset because credential handling
  # depends on whether the caller omitted the field, cleared it, or supplied a
  # new secret. A normal changeset cannot distinguish those states cleanly.
  defp provider_attrs_for_write(attrs, %Provider{} = provider) do
    attrs = normalize_external_attrs(attrs)
    credential = Map.get(attrs, "credential", @credential_omitted)

    attrs =
      attrs
      |> Map.delete("credential")
      |> maybe_preserve_credential(provider)

    with {:ok, attrs} <- reject_provider_id_change(attrs, provider),
         {:ok, attrs} <- apply_credential(attrs, provider, credential),
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

  defp apply_credential(attrs, _provider, @credential_omitted), do: {:ok, attrs}

  defp apply_credential(attrs, _provider, credential) when credential in [nil, ""],
    do: {:ok, Map.put(attrs, "encrypted_credential", nil)}

  defp apply_credential(attrs, %Provider{id: row_id}, credential)
       when is_binary(credential) and is_binary(row_id) do
    case String.trim(credential) do
      "" ->
        {:ok, Map.put(attrs, "encrypted_credential", nil)}

      credential ->
        with {:ok, encrypted} <- Crypto.seal(credential, row_id) do
          {:ok, Map.put(attrs, "encrypted_credential", encrypted)}
        end
    end
  end

  defp apply_credential(_attrs, _provider, _credential), do: {:error, :invalid_credential}

  defp normalize_connection_options(attrs, provider) do
    provider_kind = Map.get(attrs, "provider_kind") || provider_kind(provider)
    options = Map.get(attrs, "connection_options", connection_options(provider))

    with {:ok, normalized} <-
           Providers.normalize_connection_options(provider_kind, options || %{}) do
      {:ok, Map.put(attrs, "connection_options", normalized)}
    end
  end

  defp runtime_base_url(%Provider{base_url: base_url}, _provider_kind)
       when is_binary(base_url) and base_url != "",
       do: {:ok, base_url}

  defp runtime_base_url(_provider, %{default_base_url: base_url})
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

  defp provider_kind(%Provider{provider_kind: provider_kind}), do: provider_kind
  defp provider_kind(_provider), do: nil

  defp connection_options(%Provider{connection_options: options}) when is_map(options),
    do: options

  defp connection_options(_provider), do: %{}

  defp provider_metadata(provider_kind) do
    case Providers.fetch(provider_kind) do
      {:ok, provider_kind} ->
        %{
          "provider_strategy" => provider_kind.provider_strategy,
          "capabilities" => provider_kind.capabilities,
          "endpoint_modes" => provider_kind.endpoint_modes,
          "model_catalog_policy" => provider_kind.model_catalog_policy
        }

      {:error, _reason} ->
        %{}
    end
  end

  # Live-checks are intentionally provider-owned. A simple `/models` endpoint is
  # enough for OpenAI-compatible APIs, but Azure and Claude need distinct paths
  # and auth headers. Keeping this here avoids teaching Console about providers.
  defp live_check_request(
         %Provider{provider_kind: provider_kind} = provider,
         connection,
         credential
       )
       when provider_kind in [
              "openrouter",
              "openai",
              "openai-compatible",
              "google_ai_studio_openai"
            ] do
    {:ok,
     %{
       url: endpoint_url(connection, "models"),
       endpoint: "/models",
       http_protocol: Map.fetch!(connection, "http_protocol"),
       headers: live_check_headers(provider, connection, credential)
     }}
  end

  defp live_check_request(
         %Provider{provider_kind: "azure_openai"} = provider,
         connection,
         credential
       ) do
    {path, endpoint} = azure_live_check_path(connection)

    {:ok,
     %{
       url: endpoint_url(connection, path),
       endpoint: endpoint,
       http_protocol: Map.fetch!(connection, "http_protocol"),
       headers: live_check_headers(provider, connection, credential)
     }}
  end

  defp live_check_request(%Provider{provider_kind: "claude"} = provider, connection, credential) do
    {:ok,
     %{
       url: endpoint_url(connection, "v1/models"),
       endpoint: "/v1/models",
       http_protocol: Map.fetch!(connection, "http_protocol"),
       headers: live_check_headers(provider, connection, credential)
     }}
  end

  defp live_check_request(_provider, _connection, _credential),
    do: {:error, :unsupported_provider_kind}

  defp endpoint_url(connection, path) do
    base_url =
      connection
      |> Map.fetch!("base_url")
      |> String.trim_trailing("/")

    "#{base_url}/#{path}"
  end

  # Azure OpenAI accepts both account-root endpoints and `/openai` or
  # `/openai/v1` base URLs. The model-list path follows the same family choice
  # as request dispatch so live-checks do not pass while real calls fail.
  defp azure_live_check_path(connection) do
    base_url = Map.get(connection, "base_url", "") |> to_string()
    api_version = Map.get(connection, "api_version") || "2025-04-01-preview"
    query = "?api-version=#{URI.encode_www_form(api_version)}"

    cond do
      azure_v1_base_url?(base_url) ->
        {"models", "/models"}

      azure_openai_base_url?(base_url) ->
        {"models#{query}", "/models"}

      true ->
        {"openai/models#{query}", "/openai/models"}
    end
  end

  defp azure_v1_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) -> String.contains?(path, "/openai/v1")
      _uri -> false
    end
  end

  defp azure_openai_base_url?(base_url) do
    case URI.parse(base_url) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/", trim: true)
        |> Enum.member?("openai")

      _uri ->
        false
    end
  end

  defp connection_headers(connection) do
    connection
    |> Map.get("headers", %{})
    |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  # Reuses provider auth/header callbacks for live-checks so a provider with
  # non-bearer auth cannot accidentally work in turns but fail in Console.
  defp live_check_headers(provider, connection, credential) do
    runtime = %{
      "provider_kind" => provider.provider_kind,
      "connection_options" => connection,
      "credential_mode" => provider.credential_mode,
      "credential" => credential
    }

    case Providers.module_for_runtime(runtime) do
      {:ok, module} ->
        connection
        |> connection_headers()
        |> module.put_headers(runtime)
        |> module.put_auth_headers(runtime)
        |> Map.to_list()

      {:error, _reason} ->
        connection_headers(connection) |> Map.to_list()
    end
  end

  defp call_live_check_client(http_client, request) when is_function(http_client, 1) do
    http_client.(request)
  end

  defp call_live_check_client(http_client, request) when is_function(http_client, 3) do
    http_client.(request.url, request.headers, request.timeout_ms)
  end

  defp http_get(%{url: url, headers: headers, timeout_ms: timeout_ms} = request) do
    # Keep Req as transport only. Provider live checks do not decode response
    # JSON, and all JSON work in the AI gateway path goes through Ankole.JSON.
    with {:ok, protocols} <- HttpProtocol.finch_protocols(request.http_protocol),
         {:ok, response} <-
           Req.get(
             url: url,
             headers: headers,
             decode_body: false,
             retry: false,
             receive_timeout: timeout_ms,
             connect_options: [protocols: protocols, timeout: timeout_ms]
           ) do
      case response.status do
        status when status in 200..299 ->
          {:ok, %{"status" => "ok", "http_status" => status}}

        status ->
          {:error,
           {:provider_live_check_failed,
            %{
              "http_status" => status,
              "reason" => "upstream_error",
              "body" => truncate_body(response.body)
            }}}
      end
    else
      {:error, :invalid_http_protocol} ->
        {:error, :invalid_http_protocol}

      {:error, reason} ->
        {:error, {:provider_live_check_failed, reason}}
    end
  end

  defp credential_mask(value) when is_binary(value), do: "********"
  defp credential_mask(_value), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 2_000)
  defp truncate_body(body), do: inspect(body)

  defp normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_id(value), do: value
end
