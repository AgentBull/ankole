defmodule BullX.Config.ApplicationBinding do
  @moduledoc """
  Skogsra binding for values already present in application config.

  This binding lets BullX use compile/runtime `Application` env as one source
  in the same ordered config chain as OS env and database-backed config, while
  still applying BullX validation before the value is accepted.
  """

  use Skogsra.Binding

  @impl Skogsra.Binding
  def get_env(%Skogsra.Env{} = env, _state) do
    env
    |> fetch_application_value()
    |> validate_application_value(env)
  end

  defp fetch_application_value(%Skogsra.Env{app_name: app_name, keys: keys}) do
    case List.wrap(keys) do
      [] ->
        :error

      [key] ->
        Application.fetch_env(app_name, key)

      [key | rest] ->
        with {:ok, value} <- Application.fetch_env(app_name, key) do
          fetch_path(value, rest)
        end
    end
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(value, [key | rest]) when is_list(value) do
    case Keyword.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _keys), do: :error

  defp validate_application_value({:ok, value}, env) do
    case BullX.Config.Validation.validate_runtime_raw(env, value) do
      :ok -> {:ok, value}
      {:error, _} -> nil
    end
  end

  defp validate_application_value(:error, _env), do: nil
end
