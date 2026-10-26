defmodule Ankole.AuthZ.Rule do
  @moduledoc false
  defstruct [:name, :resource, :action, :permissions, check: :grant, __spark_metadata__: nil]
end
