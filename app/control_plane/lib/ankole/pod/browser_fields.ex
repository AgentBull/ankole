defmodule Ankole.Pod.BrowserFields do
  @moduledoc "Shared field contracts for Pod browser operations, independent of domain code."
  @doc "The author profile fields shared by Pod browser responses."
  def author_fields do
    [
      principal_uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
      name: [type: :string],
      kind: [type: :atom, constraints: [one_of: [:human, :agent, :system]]],
      avatar_url: [type: :string]
    ]
  end
end
