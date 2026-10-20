defmodule AnkoleWeb.ConsoleErrors do
  @moduledoc """
  Shared renderer for console REST API error envelopes.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  @doc """
  Renders the console `%{error: %{code, message, details}}` envelope.
  """
  def render(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end

  @doc """
  Renders an unlisted error reason without leaking internal terms.

  An unlisted reason is a server-side gap: the warning log carries the full
  reason for the operator, and the response stays generic. `log_event` names
  the owning API, for example `"ai_gateway.provider_api.unexpected_error"`.
  """
  def unexpected(conn, log_event, reason) do
    Ankole.Logging.warning(
      log_event,
      "console API request failed for an unhandled reason",
      %{reason: inspect(reason)}
    )

    render(
      conn,
      422,
      "invalid_value",
      "the request failed for an unexpected reason; check the server log"
    )
  end

  @doc """
  Renders the shared adapter configuration decode failures as field-scoped
  validation errors.

  `Ankole.Plugins.MapHelpers` and the adapter config validators return these
  reason shapes for one named field. The details carry the field path so the
  console can point at the field instead of showing a generic message. Returns
  `:unhandled` for every other reason, so the caller keeps its own fallback.
  """
  def render_config_field_error(conn, reason) do
    case config_field_error(reason) do
      {message, details} -> render(conn, 422, "validation_failed", message, details)
      :unhandled -> :unhandled
    end
  end

  defp config_field_error({:missing, key}) when is_binary(key),
    do: {"#{key} is required", [%{path: key, kind: "missing"}]}

  defp config_field_error({:invalid_string, key}) when is_binary(key),
    do: {"#{key} is invalid", [%{path: key, kind: "invalid"}]}

  defp config_field_error({:invalid_field, key}) when is_binary(key),
    do: {"#{key} is invalid", [%{path: key, kind: "invalid"}]}

  defp config_field_error({:invalid_boolean, key}) when is_binary(key),
    do: {"#{key} must be true or false", [%{path: key, kind: "invalid"}]}

  defp config_field_error({:invalid_integer_range, key, min, max}) when is_binary(key),
    do: {"#{key} must be an integer between #{min} and #{max}", [%{path: key, kind: "invalid"}]}

  defp config_field_error({:invalid_enum, key, values}) when is_binary(key) and is_list(values),
    do: {"#{key} must be one of: #{Enum.join(values, ", ")}", [%{path: key, kind: "invalid"}]}

  defp config_field_error(_reason), do: :unhandled

  @doc """
  Converts changeset errors into the console API detail list.
  """
  def changeset_details(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_changeset_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{path: to_string(field), message: &1})
    end)
  end

  defp format_changeset_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", to_string(value))
    end)
  end
end
