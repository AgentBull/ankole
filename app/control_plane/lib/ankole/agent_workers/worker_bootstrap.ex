defmodule Ankole.AgentWorkers.WorkerBootstrap do
  @moduledoc "The launch contract of one generation of one Agent's Worker."

  alias Ankole.AgentWorkers.Providers.Runtime
  alias Ankole.AgentWorkers.WorkerBootstrap.AgentWorkerSpec

  @builtin_skills_root "/repo/app/library"
  @internal_skills_root "/repo/internals/skills"
  @installed_skills_root "/workspace/installed-skills"

  @spec agent_worker_spec(Runtime.t(), String.t(), String.t(), String.t(), map() | nil) ::
          AgentWorkerSpec.t()
  def agent_worker_spec(provider, agent_uid, generation, token, storage_ref \\ nil) do
    env =
      %{
        "WORKER_ID" => agent_uid,
        "ANKOLE_WORKER_TENANT_ID" => Ankole.Repo.tenant_id!(),
        "ANKOLE_WORKER_STORAGE_NAME" =>
          Ankole.AgentWorkers.ProviderKind.storage_name(provider.runtime.installation, agent_uid),
        "ANKOLE_RUNTIME_FABRIC_ENDPOINT" =>
          get_in(provider.settings, ["endpoints", "runtimeFabricUrl"]) ||
            provider.runtime.runtime_fabric_endpoint,
        "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => token,
        "ANKOLE_WORKER_STORAGE" => "mounted"
      }
      |> maybe_put_env("ANKOLE_VERSION", System.get_env("ANKOLE_VERSION"))
      |> maybe_put_env("ANKOLE_ENV", System.get_env("ANKOLE_ENV"))

    %AgentWorkerSpec{
      tenant_id: Ankole.Repo.tenant_id!(),
      agent_uid: agent_uid,
      generation: generation,
      image: provider.runtime.image,
      storage_ref: storage_ref,
      # A provider whose platform needs another launch form projects this one.
      env: env
    }
  end

  @doc "The Worker image owns this root; development Docker mounts use the same path."
  def internal_skills_root, do: @internal_skills_root

  @doc "The physical directory of an enabled Skill in the Worker image or installed library."
  def skill_directory(skill) do
    root =
      case {skill["source_kind"], skill["skill_root"]} do
        {"installed", _} -> @installed_skills_root
        {"builtin", "internal"} -> @internal_skills_root
        {"builtin", _} -> @builtin_skills_root
      end

    Path.join(root, skill["relative_path"])
  end

  @doc "Environment variables owned by the launch contract or the image entrypoint."
  def contract_env_names do
    ~w(WORKER_ID ANKOLE_WORKER_STORAGE_NAME ANKOLE_WORKER_TENANT_ID ANKOLE_RUNTIME_FABRIC_ENDPOINT ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY
      ANKOLE_WORKER_STORAGE ANKOLE_WORKER_TASK ANKOLE_WORKER_NFS_SOURCE
      ANKOLE_WORKER_ADAPTER_URL ANKOLE_WORKER_BOOTSTRAP ANKOLE_VERSION ANKOLE_ENV
      HOME CODEX_HOME CODEX_SQLITE_HOME)
  end

  defp maybe_put_env(env, key, value) do
    case Ankole.Attrs.optional_text(value) do
      nil -> env
      present -> Map.put(env, key, present)
    end
  end
end
