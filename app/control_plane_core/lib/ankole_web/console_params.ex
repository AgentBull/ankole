defmodule AnkoleWeb.ConsoleParams do
  @moduledoc """
  Request-parameter readers for the console controllers.

  `OpenAPISpex.Plug.CastAndValidate` replaces `conn.params` and
  `conn.body_params` with the cast request before an action runs. A declared
  parameter or body property arrives under its atom key with the type that its
  schema gives it, an undeclared query parameter is rejected with 422, and an
  operation without parameters gets an empty map. A declared name never arrives
  under a string key; only undeclared body properties that a schema permits keep
  their string keys. Controllers therefore read atom keys only.
  """

  @doc """
  Reads a required text parameter.

  Returns the trimmed text. Returns `{:error, {:missing, key}}` when the
  parameter is absent, is not a string, or is blank.
  """
  @spec text(map(), atom()) :: {:ok, String.t()} | {:error, {:missing, atom()}}
  def text(params, key) do
    case optional_text(params, key) do
      nil -> {:error, {:missing, key}}
      text -> {:ok, text}
    end
  end

  @doc """
  Reads an optional text parameter.

  Returns the trimmed text. Returns `nil` when the parameter is absent, is not a
  string, or is blank.
  """
  @spec optional_text(map(), atom()) :: String.t() | nil
  def optional_text(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  @doc """
  Reads an optional boolean parameter.

  Returns the boolean, or `default` when the parameter is absent. `false` is a
  value, not an absence.
  """
  @spec boolean(map(), atom(), default) :: boolean() | default when default: term()
  def boolean(params, key, default) do
    case Map.get(params, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  @doc """
  Reads an optional integer parameter.

  Returns the integer, or `default` when the parameter is absent. The schema
  owns the permitted range; `0` is a value, not an absence.
  """
  @spec integer(map(), atom(), default) :: integer() | default when default: term()
  def integer(params, key, default) do
    case Map.get(params, key) do
      value when is_integer(value) -> value
      _value -> default
    end
  end

  @doc """
  Reads the optional `agent` list filter.

  Returns the canonical lowercase agent UID. Returns `nil` for an absent or
  blank parameter, which selects every agent.
  """
  @spec agent_filter_param(map()) :: String.t() | nil
  def agent_filter_param(params) do
    case optional_text(params, :agent) do
      nil -> nil
      agent_uid -> String.downcase(agent_uid)
    end
  end
end
