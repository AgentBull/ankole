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
