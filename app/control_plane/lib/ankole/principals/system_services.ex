defmodule Ankole.Principals.SystemServices do
  @moduledoc "The closed set of tenant system Principals and their responsibilities."

  @services [
    %{uid: "system", purpose: "Internal tenant operations and Pod capability slots"},
    %{uid: "ankole_brain", purpose: "Brain model, embedding, and rerank calls"},
    %{uid: "ankole_applets", purpose: "Pod Applet shared AI and Web budget"}
  ]

  def display_name("system"), do: "System"
  def display_name("ankole_brain"), do: "Ankole Brain"
  def display_name("ankole_applets"), do: "Ankole Applets"
  def display_name(uid), do: uid

  def all, do: @services
  def uids, do: Enum.map(@services, & &1.uid)
  def registered?(uid), do: Enum.any?(@services, &(&1.uid == uid))

  def validate(uid) do
    if registered?(uid), do: :ok, else: {:error, :unknown_system_principal}
  end
end
