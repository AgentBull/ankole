defmodule Ankole.Authn.AddOn do
  @moduledoc "A named authentication lifecycle operation that calls its domain owner."
  @callback call(atom(), map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  defstruct [:name, :module, __spark_metadata__: nil]
end
