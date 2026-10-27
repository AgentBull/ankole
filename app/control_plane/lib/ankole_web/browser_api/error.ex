defmodule AnkoleWeb.BrowserAPI.Error do
  @moduledoc "A browser operation's public rejection, including retry information."
  use Splode.Error, fields: [:status, :code, :detail, :details], class: :invalid

  def new(status, reason, details \\ %{}) do
    text = if is_binary(reason) or is_atom(reason), do: to_string(reason), else: inspect(reason)
    exception(status: status, code: text, detail: text, details: details)
  end

  def message(error), do: error.detail

  def login({kind, seconds}) when kind in [:rate_limited],
    do: {:error, new(429, kind, %{retryAfterSeconds: seconds})}

  def login({:missing, key}), do: {:error, new(422, "#{key} is required")}
  def login(:invalid_code), do: {:error, new(401, :invalid_code)}
  def login(:invalid_email), do: {:error, new(422, :invalid_email)}
  def login(:mail_unavailable), do: {:error, new(503, :mail_unavailable)}

  def login(reason) when reason in [:login_expired, :browser_session_expired],
    do: {:error, new(401, :login_expired)}

  def login(reason) when reason in [:account_disabled, :human_access_revoked],
    do: {:error, new(403, :account_disabled)}

  def login(reason)
      when reason in [
             :not_an_admin,
             :tenant_suspended,
             :not_a_member,
             :login_policy_rejected,
             :credential_change_disabled,
             :directory_managed_member,
             :reauthentication_required
           ],
      do: {:error, new(403, reason)}

  def login(:invalid_credentials), do: {:error, new(401, :invalid_credentials)}
  def login(:invalid_authentication), do: {:error, new(401, :invalid_authentication)}
  def login(:not_found), do: {:error, new(404, :not_found)}
  def login(:identity_provider_exists), do: {:error, new(409, :identity_provider_exists)}
  def login(reason) when is_exception(reason), do: {:error, reason}
  def login(reason), do: {:error, new(400, reason)}

  defimpl AshJsonApi.ToJsonApiError do
    def to_json_api_error(error),
      do: %AshJsonApi.Error{
        status_code: error.status,
        code: error.code,
        title: error.code,
        detail: error.detail,
        meta: %{details: error.details}
      }
  end
end

defimpl AshJsonApi.ToJsonApiError, for: Ankole.Authn.Error do
  def to_json_api_error(error) do
    {:error, public_error} = AnkoleWeb.BrowserAPI.Error.login(error.reason)
    AshJsonApi.ToJsonApiError.to_json_api_error(public_error)
  end
end
