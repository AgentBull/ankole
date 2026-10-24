defmodule AnkoleWeb.BrowserAPI.Error do
  @moduledoc "A browser operation's public rejection, including retry information."
  use Splode.Error, fields: [:status, :code, :detail, :details], class: :invalid

  def new(status, reason, details \\ %{}) do
    text = if is_binary(reason) or is_atom(reason), do: to_string(reason), else: inspect(reason)
    exception(status: status, code: text, detail: text, details: details)
  end

  def message(error), do: error.detail

  def login({kind, seconds}) when kind in [:retry_locked, :retry_busy],
    do: {:error, new(429, kind, %{retryAfterSeconds: seconds})}

  def login({:missing, key}), do: {:error, new(422, "#{key} is required")}
  def login(:no_local_provider), do: {:error, new(404, :no_local_provider)}
  def login(:password_too_short), do: {:error, new(422, :password_too_short)}
  def login(:password_change_not_required), do: {:error, new(401, :change_ticket_expired)}

  def login(reason) when reason in [:login_expired, :browser_session_expired],
    do: {:error, new(401, :login_expired)}

  def login(reason) when reason in [:account_disabled, :human_access_revoked],
    do: {:error, new(403, :account_disabled)}

  def login(reason) when reason in [:not_an_admin, :tenant_suspended],
    do: {:error, new(403, reason)}

  def login(:invalid_credentials), do: {:error, new(401, :invalid_credentials)}
  def login(reason) when is_exception(reason), do: {:error, reason}
  def login(reason), do: {:error, reason}

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
