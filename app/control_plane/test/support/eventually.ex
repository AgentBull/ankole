defmodule Ankole.Eventually do
  @moduledoc false

  def eventually(fun), do: eventually(fun, 100)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
