defmodule BullX.Config.Validation do
  @doc """
  Validates a raw runtime source before it is handed back to Skogsra.

  When no Zoi schema is declared, bindings can return the raw value and let
  Skogsra perform the single authoritative cast. When Zoi is declared, we need
  a temporary cast here so the constraint can be checked without returning a
  typed value that Skogsra would try to cast again.
  """
  def validate_runtime_raw(%Skogsra.Env{} = env, raw) do
    case extract_zoi(env) do
      nil ->
        :ok

      _schema ->
        with {:ok, casted} <- Skogsra.Type.cast(env, raw),
             {:ok, _} <- parse(env, casted) do
          :ok
        else
          :error -> {:error, :invalid}
          {:error, _} -> {:error, :invalid}
        end
    end
  end

  @doc """
  Validates a value against Zoi at bootstrap time. Raises with a descriptive
  message on failure instead of returning an error tuple.
  """
  def validate_bootstrap!(value, opts) when is_list(opts) do
    case parse(opts, value) do
      {:ok, _} ->
        value

      {:error, errors} ->
        raise "BullX.Config.Bootstrap: Zoi validation failed for value #{inspect(value)}: #{inspect(errors)}"
    end
  end

  def validate_bootstrap!(value, %Skogsra.Env{} = env) do
    validate_bootstrap!(value, env.options || [])
  end

  defp extract_zoi(%Skogsra.Env{options: options}) do
    normalize_schema(Keyword.get(options || [], :zoi))
  end

  defp extract_zoi(opts) when is_list(opts) do
    normalize_schema(Keyword.get(opts, :zoi))
  end

  defp normalize_schema(nil), do: nil
  defp normalize_schema(fun) when is_function(fun, 0), do: fun.()
  defp normalize_schema(schema), do: schema

  defp parse(env_or_opts, value) do
    case extract_zoi(env_or_opts) do
      nil -> {:ok, value}
      schema -> Zoi.parse(schema, value)
    end
  end
end
