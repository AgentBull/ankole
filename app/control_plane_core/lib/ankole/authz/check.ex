defmodule Ankole.AuthZ.Check do
  @moduledoc "A strict execution guard or a row visibility filter for the existing permission engine."
  @callback check(Ankole.AuthZ.Actor.t(), term()) :: :ok | {:ok, map()} | {:error, term()}
end
