defmodule Ankole.Files.Source do
  @moduledoc """
  Sources that may create a drive file.
  """

  @sources ~w(inbound generated sent agent console pod)

  @spec all() :: [String.t()]
  def all, do: @sources
end
