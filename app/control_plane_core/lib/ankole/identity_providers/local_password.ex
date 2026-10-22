defmodule Ankole.IdentityProviders.LocalPassword do
  def platform_application(_config), do: {:ok, nil}

  @moduledoc """
  Built-in email-and-password identity provider.

  This adapter is part of the control plane, not a plugin, so setup and the
  console always list it. Each tenant holds at most one local provider
  instance (`save_provider` rejects a second one), because every instance
  in that tenant would read and write the same credentials.

  Sign-in verifies an Argon2id hash through the kernel. Accounts only come
  from the console, setup, or the rescue command; there is no self-service
  registration and email addresses are trusted without verification.

  This module owns the password rules, hashing, authentication, and retry
  protection. `Ankole.Principals` owns the credential rows: this module gives
  it password hashes, never plain passwords.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals
  alias Ankole.Principals.LocalCredential
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @adapter_contract_id "principals.identity_provider"
  @adapter_id "local"
  @plugin_id "control-plane"
  @capability "password_login"
  @config_key_pattern ~r/\Aprincipals\.identity_providers\.local\.[a-z][a-z0-9_-]*\z/
  @local_password_min_length 6

  # Hash of a throwaway string, verified when the email has no credential so
  # the response time does not tell the caller whether the account exists. A
  # baked constant keeps that timing identical from the first request on.
  @dummy_password_hash "$argon2id$v=19$m=19456,t=2,p=1$lN2XWliZcQl4gHsXITedAg$DDmr4D0bb5laGYLf46hR2ubMwUfsd5HD1Oz71V/yDAo"

  @type authenticate_result ::
          {:ok,
           %{
             principal_uid: String.t(),
             provider_id: String.t(),
             email: String.t(),
             credential_version: non_neg_integer(),
             must_change_password: boolean()
           }}
          | {:error, :invalid_credentials}
          | {:error, :account_disabled}
          | {:error, {:retry_locked, pos_integer()}}
          | {:error, {:retry_busy, pos_integer()}}
          | {:error, :password_verification_failed}
          | {:error, :no_local_provider}

  @doc """
  Returns the built-in adapter id.
  """
  @spec adapter_id() :: String.t()
  def adapter_id, do: @adapter_id

  @doc """
  Returns the password-login capability id.
  """
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc """
  Returns the adapter declaration for the identity-provider catalog.
  """
  @spec adapter_declaration() :: map()
  def adapter_declaration do
    %{
      contract_id: @adapter_contract_id,
      id: @adapter_id,
      plugin_id: @plugin_id,
      display_name: %{
        "default" => "Local accounts",
        "zh-Hans-CN" => "本地账户密码",
        "ja-JP" => "ローカルアカウント",
        "ko-KR" => "로컬 계정"
      },
      fields: [
        %{
          path: "retry_protection.enabled",
          label: %{
            "default" => "Password retry protection",
            "zh-Hans-CN" => "密码重试保护"
          },
          description: %{
            "default" =>
              "Allow at most 5 failed password attempts per account inside 30 minutes; more attempts must wait. Keep this on unless it blocks your team.",
            "zh-Hans-CN" => "同一账户 30 分钟内最多尝试 5 次密码，超出需等待冷却。建议保持开启。"
          },
          type: "boolean",
          default: true,
          advanced: true
        }
      ],
      module: __MODULE__,
      capabilities: [@capability]
    }
  end

  @doc """
  Returns the AppConfigure pattern for local provider configuration keys.
  """
  @spec app_config_pattern() :: AppConfigure.PatternDefinition.t()
  def app_config_pattern do
    AppConfigure.define_pattern(
      scope: :tenant,
      id: "principals.identity_providers.local.*",
      key_pattern: @config_key_pattern,
      console_writable: false,
      # The local provider config holds one boolean and no secret.
      encrypted: false,
      schema: Schema.new(&validate_config/1),
      description: "Built-in local email-and-password identity provider configuration."
    )
  end

  @doc """
  Tells whether an enabled local provider exists in the activation list.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    match?({:ok, _provider}, fetch_enabled_provider())
  end

  @doc """
  Fetches the enabled local provider entry from the activation list.
  """
  @spec fetch_enabled_provider() :: {:ok, map()} | {:error, :no_local_provider}
  def fetch_enabled_provider do
    with {:ok, providers} <- Config.active_providers(),
         %{} = provider <-
           Enum.find(
             providers,
             &(&1["adapter_id"] == @adapter_id and &1["enabled"] != false)
           ) do
      {:ok, provider}
    else
      _missing -> {:error, :no_local_provider}
    end
  end

  @doc """
  Returns the minimum accepted length for a local password.
  """
  @spec local_password_min_length() :: pos_integer()
  def local_password_min_length, do: @local_password_min_length

  @doc """
  Hashes and stores a caller-chosen local password for one human user.
  """
  @spec set_local_password(String.t(), String.t(), boolean()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def set_local_password(uid, password, must_change_password)
      when is_boolean(must_change_password) do
    with {:ok, uid} <- Principals.normalize_uid(uid),
         :ok <- validate_local_password(password),
         {:ok, password_hash} <- hash_password(password) do
      Principals.put_local_credential(uid, password_hash, must_change_password)
    end
  end

  @doc """
  Completes a forced password change for one human user.

  The write locks the credential row and requires the verified credential
  version and the must-change flag to still match.
  """
  @spec complete_forced_password_change(String.t(), String.t(), non_neg_integer()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def complete_forced_password_change(uid, new_password, credential_version) do
    with {:ok, uid} <- Principals.normalize_uid(uid),
         :ok <- validate_local_password(new_password),
         {:ok, password_hash} <- hash_password(new_password) do
      Principals.complete_forced_password_change(uid, password_hash, credential_version)
    end
  end

  @doc """
  Replaces one human user's local password with a generated initial password.
  """
  @spec reset_local_password(String.t(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def reset_local_password(uid, must_change_password \\ true)
      when is_boolean(must_change_password) do
    initial_password = LocalCredential.generate_initial_password()

    with {:ok, uid} <- Principals.normalize_uid(uid),
         {:ok, password_hash} <- hash_password(initial_password),
         {:ok, _credential} <-
           Principals.put_local_credential(uid, password_hash, must_change_password) do
      {:ok, initial_password}
    end
  end

  @doc """
  Replaces the local password for the human user that owns one email address.
  """
  @spec reset_local_password_by_email(String.t()) ::
          {:ok, %{principal_uid: String.t(), initial_password: String.t()}} | {:error, term()}
  def reset_local_password_by_email(email) do
    with {:ok, %{principal: principal}} <- fetch_local_login(email),
         {:ok, initial_password} <- reset_local_password(principal.uid, true) do
      {:ok, %{principal_uid: principal.uid, initial_password: initial_password}}
    end
  end

  @doc """
  Loads the Principal, human profile, and local credential for one email.
  """
  @spec fetch_local_login(String.t()) ::
          {:ok,
           %{
             principal: Principal.t(),
             human_user: HumanUser.t(),
             credential: LocalCredential.t() | nil
           }}
          | {:error, :not_found}
  def fetch_local_login(email) do
    case Principals.normalize_email(email) do
      nil ->
        {:error, :not_found}

      normalized ->
        Principals.fetch_local_login(normalized)
    end
  end

  @doc """
  Hashes a local password with Argon2id.

  Hashing runs before the credential write, outside its transaction.
  """
  @spec hash_password(String.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_password(password) do
    case NativeKernel.argon2id_hash(password) do
      hash when is_binary(hash) -> {:ok, hash}
      {:error, reason} -> {:error, {:password_hash_failed, reason}}
    end
  end

  @doc """
  Verifies an email and password pair against the local credential store.

  A miss on the email runs one verify against a throwaway hash, so the
  response time does not tell the caller whether the account exists.
  """
  @spec authenticate(String.t(), String.t(), keyword()) :: authenticate_result()
  def authenticate(email, password, opts \\ [])

  def authenticate(email, password, _opts) when is_binary(email) and is_binary(password) do
    with {:ok, provider} <- fetch_enabled_provider() do
      retry_protection? = retry_protection_enabled?(provider)
      account_key = Principals.normalize_email(email) || ""
      login = fetch_local_login(account_key)

      password_hash =
        case login do
          {:ok, %{credential: %LocalCredential{} = credential}} -> credential.password_hash
          _missing_login_or_credential -> @dummy_password_hash
        end

      case RetryGuard.verify_password(Repo.tenant_id!(), account_key, password, password_hash,
             retry_protection?: retry_protection?,
             clear_on_match?: match?({:ok, %{credential: %LocalCredential{}}}, login),
             not_before_us: credential_written_at_us(login)
           ) do
        {:ok, true} -> verified_login(provider, login, account_key)
        {:ok, false} -> {:error, :invalid_credentials}
        {:locked, seconds} -> {:error, {:retry_locked, seconds}}
        {:busy, seconds} -> {:error, {:retry_busy, seconds}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def authenticate(_email, _password, _opts), do: {:error, :invalid_credentials}

  defp verified_login(
         provider,
         {:ok, %{credential: %LocalCredential{} = credential} = login},
         account_key
       ),
       do: authenticated_result(provider, login, credential, account_key)

  defp verified_login(_provider, _missing_login_or_credential, _account_key),
    do: {:error, :invalid_credentials}

  defp authenticated_result(
         provider,
         %{principal: %Principal{status: :active} = principal},
         credential,
         account_key
       ) do
    {:ok,
     %{
       principal_uid: principal.uid,
       access_version: principal.access_version,
       auth_time: System.system_time(:second),
       provider_id: provider["provider_id"],
       email: account_key,
       credential_version: LocalCredential.version(credential),
       must_change_password: credential.must_change_password
     }}
  end

  defp authenticated_result(_provider, _login, _credential, _account_key),
    do: {:error, :account_disabled}

  defp validate_local_password(password) when is_binary(password) do
    case String.length(password) >= @local_password_min_length do
      true -> :ok
      false -> {:error, :password_too_short}
    end
  end

  defp validate_local_password(_password), do: {:error, :password_too_short}

  defp credential_written_at_us(
         {:ok, %{credential: %LocalCredential{updated_at: %DateTime{} = at}}}
       ),
       do: DateTime.to_unix(at, :microsecond)

  defp credential_written_at_us(_login), do: nil

  defp retry_protection_enabled?(provider) do
    with config_key when is_binary(config_key) <- provider["config_key"],
         {:ok, config} when is_map(config) <- AppConfigure.get_by_key(config_key) do
      get_in(config, ["retry_protection", "enabled"]) != false
    else
      _missing_or_error -> true
    end
  end

  defp validate_config(value) when is_map(value) do
    case get_in(value, ["retry_protection", "enabled"]) do
      nil -> {:ok, value}
      enabled when is_boolean(enabled) -> {:ok, value}
      _other -> {:error, {:invalid_boolean, "retry_protection.enabled"}}
    end
  end

  defp validate_config(_value), do: {:error, :not_json_object}
end
