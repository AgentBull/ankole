defmodule AnkoleWeb.ConsoleErrors do
  @moduledoc """
  Shared action fallback and renderer for console REST API errors.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Ankole.Errors.Invalid.{Conflict, NotFound, Rejected, Stale, StatusTransition}

  @conflicts [
    Stale,
    StatusTransition,
    Ash.Error.Changes.StaleRecord,
    AshStateMachine.Errors.NoMatchingTransition
  ]

  @behaviour Plug

  @impl true
  def init(failure), do: failure

  @impl true
  def call(conn, failure), do: fallback(conn, failure)

  @doc """
  Handles a failed Console action.

  Authorization failures share one response. An `Ash.Error.Invalid` error uses
  the declared vocabulary of `Ankole.Errors`: a stale write or a refused state
  transition gives 409, a missing target gives 404, a declared rejection or
  conflict goes to the controller's local handler as its reason, and other errors are field
  validation failures (422). Framework and unknown errors are logged and give
  a generic response.

  A controller with business errors supplies its local handler for every other
  reason. The `validation:` option sets the code and message of a validation
  failure as `{code, message}`, or as a function that receives the connection
  and the validation details.
  """
  def fallback(conn, failure, local_error \\ nil, opts \\ [])

  def fallback(conn, {:error, :forbidden}, _local_error, _opts), do: forbidden(conn)

  def fallback(conn, {:error, %Ash.Changeset{} = changeset}, local_error, opts),
    do: fallback(conn, {:error, Ash.Error.to_error_class(changeset)}, local_error, opts)

  def fallback(conn, {:error, %Ash.Error.Invalid{errors: errors} = error}, local_error, opts) do
    case declared_error(errors) do
      :conflict -> conflict(conn)
      :not_found -> not_found(conn, "the resource was not found")
      {:rejected, reason} -> fallback(conn, {:error, reason}, local_error, opts)
      nil -> validation(conn, error, Keyword.get(opts, :validation))
    end
  end

  def fallback(conn, {:error, %module{} = error}, _local_error, _opts)
      when module in [Ash.Error.Framework, Ash.Error.Unknown],
      do: unexpected(conn, "console.ash.unexpected_error", error)

  def fallback(conn, {:error, {:missing, key}}, nil, _opts), do: required_field(conn, key)

  def fallback(conn, {:error, reason}, local_error, _opts) when is_function(local_error, 2),
    do: local_error.(conn, reason)

  defp declared_error(errors) do
    Enum.find_value(errors, fn
      %Rejected{reason: reason} -> {:rejected, reason}
      %Conflict{reason: reason} -> {:rejected, reason}
      %module{} when module in @conflicts -> :conflict
      %NotFound{} -> :not_found
      _error -> nil
    end)
  end

  defp validation(conn, error, nil), do: changeset(conn, error)

  defp validation(conn, error, {code, message}),
    do: render(conn, 422, code, message, changeset_details(error))

  defp validation(conn, error, local_validation) when is_function(local_validation, 2),
    do: local_validation.(conn, changeset_details(error))

  defp conflict(conn),
    do:
      render(
        conn,
        409,
        "conflict",
        "the resource changed or does not permit this change; reload it and try again"
      )

  @doc "Renders a Console authorization failure."
  def forbidden(conn, message \\ "access denied"), do: render(conn, 403, "forbidden", message)

  @doc "Renders a missing Console resource with its owning controller's message."
  def not_found(conn, message), do: render(conn, 404, "not_found", message)

  @doc "Renders a Console changeset validation failure."
  def changeset(conn, changeset, message \\ "request validation failed"),
    do: render(conn, 422, "validation_failed", message, changeset_details(changeset))

  @doc """
  Renders the console `%{error: %{code, message, details}}` envelope.
  """
  def render(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end

  @doc "Renders a missing required Console field."
  def required_field(conn, key),
    do: render(conn, 422, "validation_failed", "#{key} is required")

  @doc """
  Renders an unlisted error reason without leaking internal terms.

  An unlisted reason is a server-side gap: the warning log carries the failure
  class for the operator, and the response stays generic. `log_event` names
  the owning API, for example `"ai_gateway.provider_api.unexpected_error"`.
  A controller can keep its own code and message for the response.
  """
  def unexpected(
        conn,
        log_event,
        reason,
        code \\ "invalid_value",
        message \\ "the request failed for an unexpected reason; check the server log"
      ) do
    Ankole.Logging.warning(
      log_event,
      "console API request failed for an unhandled reason",
      Ankole.Logging.failure_fields(:error, reason, [])
    )

    render(conn, 422, code, message)
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
  def changeset_details(%module{} = error) when module in [Ash.Changeset, Ash.Error.Invalid],
    do: Ankole.Ash.validation_details(error)
end
