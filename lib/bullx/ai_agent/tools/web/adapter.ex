defmodule BullX.AIAgent.Tools.Web.Adapter do
  @moduledoc false

  @enforce_keys [:id, :module, :supports]
  defstruct [:id, :module, :supports]

  @type kind :: :search | :extract
  @type t :: %__MODULE__{id: String.t(), module: module(), supports: [kind()]}
end
