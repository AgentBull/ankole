defmodule Ankole.ModelIntegerID do
  @moduledoc "Model-visible integer IDs and their canonical decimal wire form."

  @minimum 1000
  @maximum 9_007_199_254_740_991

  @spec minimum() :: pos_integer()
  def minimum, do: @minimum

  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  defguard valid?(value) when is_integer(value) and value in @minimum..@maximum

  @spec parse(term()) :: {:ok, pos_integer()} | :error
  def parse(value) when valid?(value), do: {:ok, value}

  def parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when valid?(id) ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: :error

      _invalid ->
        :error
    end
  end

  def parse(_value), do: :error
end
