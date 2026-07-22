defmodule Ankole.Plugins.GoogleWorkspaceAdapter.Config do
  @moduledoc "Validation and runtime helpers for the first-party Google Workspace adapter."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.MapHelpers
  alias GoogleOpenAPI.Client

  @identity_key_pattern ~r/\Aprincipals\.identity_providers\.google-workspace\.[A-Za-z0-9_.:-]+\z/

  @default_oidc_scopes ["openid", "email", "profile"]
  @default_namespace "google-workspace-main"
  @domain_pattern ~r/\A[a-z0-9][a-z0-9.-]*\.[a-z]{2,}\z/

  @type identity_config :: map()

  @spec app_config_patterns() :: [Ankole.AppConfigure.PatternDefinition.t()]
  def app_config_patterns do
    [
      AppConfigure.define_pattern(
        id: "principals.identity_providers.google-workspace.*",
        key_pattern: @identity_key_pattern,
        encrypted: true,
        schema: Schema.new(&validate_identity_config/1),
        description: "Encrypted Google Workspace identity-provider configuration."
      )
    ]
  end

  @spec identity_config_key(String.t()) :: String.t()
  def identity_config_key(id), do: "principals.identity_providers.google-workspace.#{id}"

  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  @spec validate_identity_config(term()) :: {:ok, identity_config()} | {:error, term()}
  def validate_identity_config(value) when is_map(value) do
    oidc = MapHelpers.fetch_map(value, "oidc", %{})
    sync = MapHelpers.fetch_map(value, "sync", %{})

    with {:ok, oidc_enabled} <- optional_boolean(oidc, "enabled", true),
         {:ok, client_id} <- required_when(value, "clientID", oidc_enabled),
         {:ok, client_secret} <- required_when(value, "clientSecret", oidc_enabled),
         {:ok, oidc_scopes} <- string_array(oidc, "scopes", @default_oidc_scopes),
         {:ok, allowed_domains} <- allowed_domains(oidc, oidc_enabled),
         {:ok, sync_contacts} <- optional_boolean(sync, "contacts", true),
         {:ok, service_account_key} <- service_account_key(value, sync_contacts),
         {:ok, admin_email} <- admin_email(value, sync_contacts),
         {:ok, page_size} <- integer_between(sync, "pageSize", 500, 1, 500),
         {:ok, include_suspended} <- optional_boolean(sync, "includeSuspended", false) do
      {:ok,
       %{
         "clientID" => client_id,
         "clientSecret" => client_secret,
         "oidc" => %{
           "enabled" => oidc_enabled,
           "scopes" => oidc_scopes,
           "allowedDomains" => allowed_domains
         },
         "serviceAccountKey" => service_account_key,
         "adminEmail" => admin_email,
         "sync" => %{
           "contacts" => sync_contacts,
           "pageSize" => page_size,
           "includeSuspended" => include_suspended
         }
       }}
    end
  end

  def validate_identity_config(_value), do: {:error, :invalid_identity_config}

  @spec load_identity_config_key(String.t()) :: {:ok, identity_config()} | {:error, term()}
  def load_identity_config_key(key) when is_binary(key) do
    with {:ok, value} <- AppConfigure.get_by_key(key), do: validate_identity_config(value)
  end

  def load_identity_config_key(_key), do: {:error, :invalid_config_key}

  @doc """
  Builds a provider client from an identity config.

  The service-account grant is signed by the kernel through the client's
  assertion-signer closure, so key material never leaves this module's scope
  and the HTTP library stays crypto-free.
  """
  @spec identity_client(identity_config()) :: Client.t()
  def identity_client(config) do
    [client_id: Map.get(config, "clientID")]
    |> maybe_keyword(:client_secret, Map.get(config, "clientSecret"))
    |> Keyword.merge(service_account_options(config))
    |> Client.new()
  end

  @spec service_account(identity_config()) ::
          {:ok, %{email: String.t(), private_key: String.t(), key_id: String.t() | nil}}
          | {:error, term()}
  def service_account(config) do
    case Map.get(config, "serviceAccountKey") do
      nil -> {:error, :missing_service_account_key}
      raw -> parse_service_account_key(raw)
    end
  end

  defp service_account_options(config) do
    case service_account(config) do
      {:ok, account} ->
        header =
          %{"algorithm" => "RS256"}
          |> MapHelpers.maybe_put("key_id", account.key_id)

        [
          service_account_email: account.email,
          delegated_subject: Map.get(config, "adminEmail"),
          assertion_signer: fn claims ->
            case NativeKernel.jwt_sign_pem(claims, account.private_key, header) do
              token when is_binary(token) -> {:ok, token}
              {:error, reason} -> {:error, reason}
            end
          end
        ]

      {:error, _reason} ->
        []
    end
  end

  defp parse_service_account_key(raw) when is_binary(raw) do
    with {:ok, decoded} <- Torque.decode(raw),
         email when is_binary(email) <- MapHelpers.optional_text(decoded, "client_email"),
         "-----BEGIN" <> _rest = private_key <-
           MapHelpers.optional_text(decoded, "private_key") || :missing_private_key do
      {:ok,
       %{
         email: email,
         private_key: private_key,
         key_id: MapHelpers.optional_text(decoded, "private_key_id")
       }}
    else
      _invalid -> {:error, :invalid_service_account_key}
    end
  end

  defp parse_service_account_key(_raw), do: {:error, :invalid_service_account_key}

  defp allowed_domains(_oidc, false), do: {:ok, []}

  defp allowed_domains(oidc, true) do
    case MapHelpers.fetch_value(oidc, "allowedDomains") do
      domains when is_list(domains) and domains != [] ->
        normalized = Enum.map(domains, &normalize_domain/1)

        if Enum.all?(normalized, &is_binary/1) do
          {:ok, normalized}
        else
          {:error, {:invalid_domain, "oidc.allowedDomains"}}
        end

      _missing_or_empty ->
        {:error, {:missing, "oidc.allowedDomains"}}
    end
  end

  defp normalize_domain(value) when is_binary(value) do
    domain = value |> String.trim() |> String.downcase()
    if Regex.match?(@domain_pattern, domain), do: domain, else: nil
  end

  defp normalize_domain(_value), do: nil

  defp service_account_key(value, true) do
    with {:ok, raw} <- required_string(value, "serviceAccountKey"),
         {:ok, _parsed} <- parse_service_account_key(raw) do
      {:ok, raw}
    end
  end

  defp service_account_key(value, false),
    do: {:ok, MapHelpers.optional_text(value, "serviceAccountKey")}

  defp admin_email(value, true) do
    with {:ok, email} <- required_string(value, "adminEmail") do
      if String.contains?(email, "@") do
        {:ok, String.downcase(email)}
      else
        {:error, {:invalid_email, "adminEmail"}}
      end
    end
  end

  defp admin_email(value, false), do: {:ok, MapHelpers.optional_text(value, "adminEmail")}

  defp required_when(map, key, true), do: required_string(map, key)
  defp required_when(map, key, false), do: {:ok, MapHelpers.optional_text(map, key)}

  defp required_string(map, key) do
    case MapHelpers.optional_text(map, key) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp optional_boolean(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp integer_between(map, key, default, min, max) do
    case MapHelpers.fetch_value(map, key) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      nil -> {:ok, default}
      _value -> {:error, {:invalid_integer_range, key, min, max}}
    end
  end

  defp string_array(map, key, default) do
    case MapHelpers.fetch_value(map, key) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:error, {:invalid_string_array, key}}
        end

      nil ->
        {:ok, default}

      _value ->
        {:error, {:invalid_string_array, key}}
    end
  end

  defp maybe_keyword(keyword, _key, nil), do: keyword
  defp maybe_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)
end
