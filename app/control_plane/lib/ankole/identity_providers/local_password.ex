defmodule Ankole.IdentityProviders.LocalPassword do
  @moduledoc """
  Built-in email-and-password identity provider.

  This adapter is part of the control plane, not a plugin, so setup and the
  console always list it. One installation holds at most one local provider
  instance (`save_provider` rejects a second one), because every instance
  would read and write the same `human_user_local_credentials` table.

  Sign-in verifies an Argon2id hash through the kernel. Accounts only come
  from the console, setup, or the rescue command; there is no self-service
  registration and email addresses are trusted without verification.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.IdentityProviders.Config
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals
  alias Ankole.Principals.LocalCredential
  alias Ankole.Principals.Principal

  @adapter_contract_id "principals.identity_provider"
  @adapter_id "local"
  @plugin_id "control-plane"
  @capability "password_login"
  @config_key_pattern ~r/\Aprincipals\.identity_providers\.local\.[a-z][a-z0-9_-]*\z/

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
      id: "principals.identity_providers.local.*",
      key_pattern: @config_key_pattern,
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
  Verifies an email and password pair against the local credential store.

  A miss on the email runs one verify against a throwaway hash, so the
  response time does not tell the caller whether the account exists.
  """
  @spec authenticate(String.t(), String.t(), keyword()) :: authenticate_result()
  def authenticate(email, password, opts \\ [])

  def authenticate(email, password, _opts) when is_binary(email) and is_binary(password) do
    with {:ok, provider} <- fetch_enabled_provider() do
      retry_protection? = retry_protection_enabled?(provider)
      account_key = String.downcase(String.trim(email))
      login = Principals.fetch_local_login(account_key)

      # The attempt is reserved before the hash verification runs, so
      # concurrent requests cannot all pass the limit first and verify
      # without bound. A successful verify releases the reservation.
      with :ok <- register_attempt(retry_protection?, account_key, login) do
        verify_login(provider, login, account_key, password)
      end
    end
  end

  def authenticate(_email, _password, _opts), do: {:error, :invalid_credentials}

  defp verify_login(
         provider,
         {:ok, %{credential: %LocalCredential{} = credential} = login},
         account_key,
         password
       ) do
    case NativeKernel.argon2id_verify(password, credential.password_hash) do
      true ->
        RetryGuard.clear(account_key)
        authenticated_result(provider, login, credential, account_key)

      _false_or_error ->
        {:error, :invalid_credentials}
    end
  end

  defp verify_login(_provider, _missing_account_or_credential, _account_key, password) do
    NativeKernel.argon2id_verify(password, @dummy_password_hash)
    {:error, :invalid_credentials}
  end

  defp authenticated_result(
         provider,
         %{principal: %Principal{status: :active} = principal},
         credential,
         account_key
       ) do
    {:ok,
     %{
       principal_uid: principal.uid,
       provider_id: provider["provider_id"],
       email: account_key,
       credential_version: LocalCredential.version(credential),
       must_change_password: credential.must_change_password
     }}
  end

  defp authenticated_result(_provider, _login, _credential, _account_key),
    do: {:error, :account_disabled}

  defp register_attempt(false, _account_key, _login), do: :ok

  # Attempts older than the current credential do not count: guesses against a
  # replaced password prove nothing about the new one, so a rescue or console
  # reset unlocks the account at once.
  defp register_attempt(true, account_key, login) do
    case RetryGuard.register_attempt(account_key, not_before_ms: credential_written_at_ms(login)) do
      :ok -> :ok
      {:locked, retry_after_seconds} -> {:error, {:retry_locked, retry_after_seconds}}
    end
  end

  defp credential_written_at_ms(
         {:ok, %{credential: %LocalCredential{updated_at: %DateTime{} = at}}}
       ),
       do: DateTime.to_unix(at, :millisecond)

  defp credential_written_at_ms(_login), do: nil

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
