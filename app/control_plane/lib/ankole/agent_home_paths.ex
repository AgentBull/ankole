defmodule Ankole.AgentHomePaths do
  @moduledoc """
  Canonical paths shared by the control plane and Agent Computer workers.

  Paths returned here are the real absolute paths visible to Codex. PostgreSQL
  remains authoritative for domain documents; files under Agent Home are runtime projections.
  """

  @agents_root "/agents"
  @agent_key ~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/
  @documents %{"soul" => "SOUL.md", "mission" => "MISSION.md", "design" => "DESIGN.md"}

  @spec validate_agent_uid(term()) :: :ok | {:error, :invalid_agent_home_uid}
  def validate_agent_uid(uid) when is_binary(uid) do
    if Regex.match?(@agent_key, uid), do: :ok, else: {:error, :invalid_agent_home_uid}
  end

  def validate_agent_uid(_uid), do: {:error, :invalid_agent_home_uid}

  @spec home(String.t()) :: String.t()
  def home(agent_uid), do: join_agent(agent_uid, [])

  @spec user_files(String.t()) :: String.t()
  def user_files(agent_uid), do: join_agent(agent_uid, ["user-files"])

  @spec installed_skills(String.t()) :: String.t()
  def installed_skills(agent_uid), do: join_agent(agent_uid, ["installed-skills"])

  @spec session_workspace(String.t(), pos_integer()) :: String.t()
  def session_workspace(agent_uid, workspace_id),
    do: join_agent(agent_uid, ["sessions", workspace_key!(workspace_id)])

  @spec job_workspace(String.t(), pos_integer()) :: String.t()
  def job_workspace(agent_uid, job_id)
      when is_integer(job_id) and job_id in 1000..9_007_199_254_740_991,
      do: join_agent(agent_uid, ["jobs", Integer.to_string(job_id)])

  def job_workspace(_agent_uid, _job_id),
    do: raise(ArgumentError, "background Agent Job id must be a model-safe integer")

  @spec document(String.t(), String.t()) :: String.t()
  def document(agent_uid, kind), do: join_agent(agent_uid, [Map.fetch!(@documents, kind)])

  @spec user_files_lane_path(String.t(), String.t()) :: String.t()
  def user_files_lane_path(agent_uid, relative_path),
    do: lane_path(agent_uid, "user-files", relative_path)

  @spec installed_skills_lane_path(String.t(), String.t()) :: String.t()
  def installed_skills_lane_path(agent_uid, relative_path),
    do: lane_path(agent_uid, "installed-skills", relative_path)

  @spec session_lane_path(String.t(), pos_integer(), String.t()) :: String.t()
  def session_lane_path(agent_uid, workspace_id, relative_path),
    do: lane_path(agent_uid, "sessions/#{workspace_key!(workspace_id)}", relative_path)

  @spec document_lane_path(String.t(), String.t()) :: String.t()
  def document_lane_path(agent_uid, kind),
    do: Path.join(safe_agent_uid!(agent_uid), Map.fetch!(@documents, kind))

  defp join_agent(agent_uid, suffix),
    do: Path.join([@agents_root, safe_agent_uid!(agent_uid) | suffix])

  defp workspace_key!(workspace_id)
       when is_integer(workspace_id) and workspace_id in 10_000..9_007_199_254_740_991,
       do: Integer.to_string(workspace_id)

  defp workspace_key!(_workspace_id),
    do:
      raise(ArgumentError, "session workspace id must be a model-safe integer starting at 10000")

  defp lane_path(agent_uid, root, relative_path) do
    relative_path = String.trim_leading(relative_path, "/")
    Path.join([safe_agent_uid!(agent_uid), root, relative_path])
  end

  defp safe_agent_uid!(agent_uid) do
    case validate_agent_uid(agent_uid) do
      :ok -> agent_uid
      {:error, _reason} -> raise ArgumentError, "agent UID cannot own an Agent Home"
    end
  end
end
