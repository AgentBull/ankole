defmodule BullX.AIAgent.Tools.Web.Adapter do
  @moduledoc """
  Descriptor for one web capability adapter.

  `supports` states whether the adapter can handle search, extraction, or both.
  Selection code uses this data for built-in and plugin adapters uniformly.
  """

  @enforce_keys [:id, :module, :supports]
  defstruct [:id, :module, :supports]

  @type kind :: :search | :extract
  @type t :: %__MODULE__{id: String.t(), module: module(), supports: [kind()]}
end
