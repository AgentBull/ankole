defmodule Ankole.Principals.SystemServices do
  @moduledoc "The closed set of tenant system Principals and their responsibilities."

  @services [
    %{uid: "system", purpose: "Pod Applet model calls and internal tenant operations"},
    %{uid: "ankole_brain", purpose: "Brain model, embedding, and rerank calls"}
  ]

  def all, do: @services
  def uids, do: Enum.map(@services, & &1.uid)
  def registered?(uid), do: Enum.any?(@services, &(&1.uid == uid))

  def validate(uid) do
    if registered?(uid), do: :ok, else: {:error, :unknown_system_principal}
  end
end
