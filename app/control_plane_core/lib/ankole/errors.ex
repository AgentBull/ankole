defmodule Ankole.Errors do
  @moduledoc """
  The declared error vocabulary of Ankole actions.

  A resource action shapes framework errors into these exceptions through its
  default error handler (`shape/2`). A generic action returns its domain
  reason through `wrap/1`. Domain code gets the reason back through
  `reason/1`. `AnkoleWeb.ConsoleErrors` presents them in the v1 Console API.
  Each exception implements `AshJsonApi.ToJsonApiError` for the v2 JSON:API
  routers.
  """

  alias Ankole.Errors.Invalid.{Conflict, NotFound, Rejected, Stale, StatusTransition}

  @type reason ::
          :stale
          | :not_found
          | {:invalid_status_transition, from :: atom(), to :: atom()}
          | term()

  @doc """
  Shapes one framework error into the declared vocabulary.

  `Ankole.Ash.Resource` sets this function as the default `error_handler` of
  every create, update, and destroy action. The function returns other errors
  without change.
  """
  def shape(%{resource: resource}, error), do: shape_error(error, resource)
  def shape(_subject, error), do: shape_error(error, nil)

  @doc "Shapes the errors in an Ash error class."
  def shape_errors(%{errors: errors} = class) when is_list(errors),
    do: %{class | errors: Enum.map(errors, &shape_error(&1, class_resource(class)))}

  defp shape_error(%{errors: errors} = class, resource) when is_list(errors),
    do: %{class | errors: Enum.map(errors, &shape_error(&1, resource))}

  defp shape_error(%Ash.Error.Changes.StaleRecord{} = error, resource) do
    %{
      Stale.exception(resource: error.resource || resource, filter: error.filter)
      | path: error.path
    }
  end

  defp shape_error(%AshStateMachine.Errors.NoMatchingTransition{} = error, resource) do
    %{
      StatusTransition.exception(
        resource: resource,
        field: error.field,
        from: error.old_state,
        to: error.target
      )
      | path: error.path
    }
  end

  defp shape_error(error, _resource), do: error

  defp class_resource(class) do
    Enum.find_value([:changeset, :query, :action_input], fn field ->
      case Map.get(class, field) do
        %{resource: resource} -> resource
        _other -> nil
      end
    end)
  end

  @doc """
  Makes the result of a generic action `run` function use declared errors.

  A domain reason (an atom, a tuple, or another term that is not an exception)
  becomes `Ankole.Errors.Invalid.Rejected`. Without this function, Ash wraps
  such a value in `Ash.Error.Unknown`. Exceptions, error lists, and Ash
  changesets stay the same.
  """
  def wrap({:error, error}) when is_exception(error) or is_list(error), do: {:error, error}

  def wrap({:error, %module{} = subject})
      when module in [Ash.Changeset, Ash.Query, Ash.ActionInput],
      do: {:error, subject}

  def wrap({:error, reason}), do: {:error, Rejected.exception(reason: reason)}
  def wrap(result), do: result

  @doc """
  Makes the result of a generic action use declared errors, like `wrap/1`, and
  adds the operator text of a known rejection.

  `describe` gets the reason of the rejection. It gives `{detail, details}`:
  one sentence for the operator and a list of maps, one for each rejected field
  (for example `%{path: "config", line: 3, message: "..."}`), or `nil` for a
  reason without text. The v2 JSON:API error of the rejection contains them.
  `{:conflict, detail, details}` makes the rejection an
  `Ankole.Errors.Invalid.Conflict` with the same reason. An exception replaces
  the rejection, for example `Ankole.Errors.Invalid.NotFound` for a missing
  target.
  """
  @spec wrap(
          term(),
          (reason() ->
             {String.t(), [map()]}
             | {:conflict, String.t(), [map()]}
             | Exception.t()
             | nil)
        ) :: term()
  def wrap(result, describe) when is_function(describe, 1) do
    case wrap(result) do
      {:error, %Rejected{reason: reason} = rejected} ->
        case describe.(reason) do
          {detail, details} ->
            {:error, %{rejected | detail: detail, details: details}}

          {:conflict, detail, details} ->
            {:error, Conflict.exception(reason: reason, detail: detail, details: details)}

          nil ->
            {:error, rejected}

          exception when is_exception(exception) ->
            {:error, exception}
        end

      other ->
        other
    end
  end

  @doc """
  Makes a missing-target reason of a generic action `run` result an
  `Ankole.Errors.Invalid.NotFound` for the resource. An API renders it as not
  found, not as a rejection. Other results stay the same.
  """
  def not_found({:error, reason} = result, reasons, resource) when is_atom(reason) do
    if reason in reasons, do: {:error, NotFound.exception(resource: resource)}, else: result
  end

  def not_found(result, _reasons, _resource), do: result

  @doc """
  Gives the error class of an Ash changeset, query, or action input that
  rolled back a transaction.

  AshPostgres rolls back the caller's transaction with the changeset when a
  native constraint rejects a write. `Ankole.Repo` gives that rollback as the
  error class with shaped errors. Other results stay the same.
  """
  def rollback_result({:error, %module{} = subject})
      when module in [Ash.Changeset, Ash.Query, Ash.ActionInput],
      do: {:error, subject |> Ash.Error.to_error_class() |> shape_errors()}

  def rollback_result(result), do: result

  @doc """
  Gives the result shape of an `Ankole.Ash` call.

  An Ash changeset, query, or action input becomes its error class with shaped
  errors, and a declared rejection becomes its reason. A domain code interface
  gives the error class; its caller uses `reason/1`.
  """
  def boundary_result({:error, %module{}} = result)
      when module in [Ash.Changeset, Ash.Query, Ash.ActionInput],
      do: result |> rollback_result() |> boundary_result()

  def boundary_result({:error, %Ash.Error.Invalid{errors: errors} = invalid}) do
    case Enum.find_value(errors, fn
           %Rejected{reason: reason} -> {:ok, reason}
           %Conflict{reason: reason} -> {:ok, reason}
           _other -> nil
         end) do
      {:ok, reason} -> {:error, reason}
      nil -> {:error, shape_errors(invalid)}
    end
  end

  def boundary_result(result), do: result

  @doc """
  Gives back the domain reason of a failed action.

  A declared rejection gives its reason. A stale write gives `:stale`, a
  refused state transition gives `{:invalid_status_transition, from, to}`, and
  a missing target gives `:not_found`. Other results stay the same.
  """
  @spec reason(term()) :: {:error, reason()} | term()
  def reason({:error, error}), do: {:error, to_reason(error)}
  def reason(result), do: result

  defp to_reason(%{errors: errors} = class) when is_list(errors) do
    case Enum.find_value(errors, &known_reason/1) do
      {:ok, reason} -> reason
      nil -> class
    end
  end

  defp to_reason(error) do
    case known_reason(error) do
      {:ok, reason} -> reason
      nil -> error
    end
  end

  defp known_reason(%Rejected{reason: reason}), do: {:ok, reason}
  defp known_reason(%Conflict{reason: reason}), do: {:ok, reason}
  defp known_reason(%Stale{}), do: {:ok, :stale}
  defp known_reason(%Ash.Error.Changes.StaleRecord{}), do: {:ok, :stale}
  defp known_reason(%NotFound{}), do: {:ok, :not_found}

  defp known_reason(%StatusTransition{from: from, to: to}),
    do: {:ok, {:invalid_status_transition, from, to}}

  defp known_reason(%AshStateMachine.Errors.NoMatchingTransition{old_state: from, target: to}),
    do: {:ok, {:invalid_status_transition, from, to}}

  defp known_reason(_error), do: nil
end
