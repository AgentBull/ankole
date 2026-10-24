defmodule Ankole.Plugins.LarkAdapter.SubjectIdentity do
  @moduledoc """
  Selects one ordered set of Lark human subject identifiers.

  Lark uses `user_id`, `union_id`, and `open_id`. These stable platform IDs
  identify the member. Contact email addresses are separate directory facts.
  """

  alias Ankole.Plugins.MapHelpers

  import MapHelpers, only: [optional_text: 2]

  @doc """
  Returns the available Lark subject identifiers in their required order.
  """
  @spec candidates(map()) :: [String.t()]
  def candidates(subject) when is_map(subject) do
    [
      optional_text(subject, "user_id"),
      optional_text(subject, "union_id"),
      optional_text(subject, "open_id")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def candidates(_subject), do: []
end
