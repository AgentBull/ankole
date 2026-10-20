defmodule Ankole.AgentHomePaths do
  @moduledoc "Canonical paths visible in the Agent Home of each Worker."

  require Ankole.ModelIntegerID

  @spec home() :: String.t()
  def home, do: "/workspace"

  @spec session_workspace(pos_integer()) :: String.t()
  def session_workspace(workspace_id)
      when Ankole.ModelIntegerID.valid?(workspace_id) and workspace_id >= 10_000,
      do: Path.join([home(), "sessions", Integer.to_string(workspace_id)])

  def session_workspace(_workspace_id),
    do:
      raise(ArgumentError, "session workspace id must be a model-safe integer starting at 10000")
end
