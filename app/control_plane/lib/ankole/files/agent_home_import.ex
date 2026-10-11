defmodule Ankole.Files.AgentHomeImport do
  @moduledoc """
  One-time import of the files that Agents kept in their Agent Homes before
  the drive existed.

  The import reads an Agent root on this node: the directory that holds one
  Agent Home per Agent uid, `/agents` in a Worker container. For every
  directory whose name is the uid of an Agent, it copies:

    * `installed-skills/<name>/<path>` to `skills/<name>/<path>`, for each
      `<name>` that has a `SKILL.md`.

  Files named by unsent legacy Outbox attachments also enter `sent/`. The
  import adds content references without changing the delivery state. Other
  user files, Job workspaces, and session files stay in the Agent Home.

  It then copies the script directory of every Automation Job that still has
  a `legacy_directory_path` to the job's `drive_prefix`, and clears
  `legacy_directory_path` once every file that can be copied arrived. A job
  whose directory has no `main.ts`, or whose script was not copied
  completely, is reported and keeps its path, so a later run copies it.

  A directory with an Agent UID name but no Agent is the Home of an Agent
  that the old release deleted without removing its Home. The import does not
  read it and names it in the report so the operator can remove the old data.

  The import never replaces a drive file, so a second run only copies what the
  first run did not. It skips symlinks. Skills and scripts over the Worker
  transfer limit are reported; pending attachments use local storage import.
  A directory or file that it cannot read is reported too, never
  taken for an empty one: Agent Homes that a root Worker created are readable
  only by root until an operator makes them readable.
  """

  import Bitwise
  import Ecto.Query

  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Files
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.WorkerFiles

  @commit_batch 500

  @type report :: %{
          agents: non_neg_integer(),
          files: non_neg_integer(),
          jobs: non_neg_integer(),
          attachments: non_neg_integer(),
          jobs_without_script: [pos_integer()],
          deleted_agent_homes: [Path.t()],
          skipped: [{Path.t(), term()}]
        }

  @doc "Imports every Agent Home under `agents_root` and every legacy Automation Job script."
  @spec run(Path.t()) :: {:ok, report()} | {:error, term()}
  def run(agents_root) when is_binary(agents_root) do
    root = Path.expand(agents_root)

    if File.dir?(root) do
      {agents, deleted} = agents(root)

      report = %{
        agents: 0,
        files: 0,
        jobs: 0,
        attachments: 0,
        jobs_without_script: [],
        deleted_agent_homes: Enum.map(deleted, &Path.join(root, &1)),
        skipped: []
      }

      report =
        Enum.reduce(agents, report, fn agent, report ->
          Repo.with_tenant(agent.tenant_id, fn -> import_agent(root, agent.uid, report) end)
        end)

      report =
        Enum.reduce(legacy_jobs(), report, fn job, report ->
          Repo.with_tenant(job.tenant_id, fn -> import_job(root, job, report) end)
        end)

      report =
        Enum.reduce(legacy_outboxes(), report, fn outbox, report ->
          Repo.with_tenant(outbox.tenant_id, fn -> import_attachments(root, outbox, report) end)
        end)

      {:ok,
       %{
         report
         | jobs_without_script: Enum.reverse(report.jobs_without_script),
           skipped: Enum.reverse(report.skipped)
       }}
    else
      {:error, {:not_a_directory, root}}
    end
  end

  @doc "Formats an import report for an operator."
  @spec format_report(report()) :: String.t()
  def format_report(report) do
    lines =
      [
        "Imported #{report.files} files for #{report.agents} Agents and #{report.jobs} Automation Job scripts.",
        "Migrated #{report.attachments} pending outbox attachments."
      ] ++
        Enum.map(
          report.jobs_without_script,
          &"Automation Job #{&1}: no main.ts in its directory."
        ) ++
        Enum.map(
          report.deleted_agent_homes,
          &"No Agent has the UID of #{&1}: it is the Home of a deleted Agent."
        ) ++
        Enum.map(report.skipped, fn {path, reason} -> "Skipped #{path}: #{inspect(reason)}" end)

    Enum.join(lines, "\n")
  end

  # Returns Agents with stored ownership, and directory names with no Agent.
  defp agents(root) do
    names =
      root
      |> File.ls!()
      |> Enum.filter(fn name ->
        Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/, name) and File.dir?(Path.join(root, name))
      end)

    agents =
      Repo.across_tenants(fn ->
        Repo.all(
          from principal in Principal,
            where: principal.uid in ^names and principal.type == :agent,
            select: %{uid: principal.uid, tenant_id: principal.tenant_id},
            order_by: principal.uid
        )
      end)

    {agents, Enum.sort(names -- Enum.map(agents, & &1.uid))}
  end

  defp import_agent(root, agent_uid, report) do
    home = Path.join(root, agent_uid)
    skills_root = Path.join(home, "installed-skills")
    {skill_names, report} = list_dir(skills_root, report)

    skill_folders =
      for name <- skill_names, regular_file?(Path.join([skills_root, name, "SKILL.md"])) do
        {Path.join(skills_root, name), "skills/" <> name}
      end

    report =
      Enum.reduce(skill_folders, report, fn {local_dir, prefix}, report ->
        import_folder(agent_uid, local_dir, prefix, report)
      end)

    %{report | agents: report.agents + 1}
  end

  defp legacy_outboxes do
    Repo.across_tenants(fn ->
      Repo.all(
        from outbox in OutboxEntry,
          where: outbox.status != :succeeded,
          where:
            fragment(
              "jsonb_path_exists(?, '$.attachments[*].user_files_relative_path') OR jsonb_path_exists(?, '$.attachments[*].agent_computer_path')",
              outbox.payload,
              outbox.payload
            ),
          order_by: [outbox.agent_uid, outbox.binding_name, outbox.outbound_key]
      )
    end)
  end

  defp import_attachments(root, outbox, report) do
    # The upgrade runs with dispatch stopped. The row lock also makes repeat
    # imports safe and keeps a completed send's audit payload unchanged.
    result =
      with {:ok, attachments, upserts} <-
             convert_attachments(root, outbox.agent_uid, outbox.payload["attachments"] || []) do
        Repo.transact(fn repo ->
          current =
            OutboxEntry
            |> where(
              [entry],
              entry.agent_uid == ^outbox.agent_uid and entry.binding_name == ^outbox.binding_name and
                entry.outbound_key == ^outbox.outbound_key
            )
            |> lock("FOR UPDATE")
            |> repo.one!()

          if current.status == :succeeded do
            {:ok, 0}
          else
            with true <- current.payload == outbox.payload || {:error, :outbox_changed},
                 {:ok, _result} <-
                   Files.commit(repo, current.agent_uid, Enum.uniq_by(upserts, & &1.path), []),
                 {:ok, _row} <-
                   current
                   |> OutboxEntry.changeset(%{
                     payload: Map.put(current.payload, "attachments", attachments)
                   })
                   |> repo.update(),
                 {:ok, _outbox} <-
                   Ankole.SignalsGateway.Outbox.commit_outbox_in_tx(repo, %{
                     agent_uid: current.agent_uid,
                     binding_name: current.binding_name,
                     outbound_key: current.outbound_key,
                     operation: current.operation
                   }) do
              {:ok, length(upserts)}
            end
          end
        end)
      end

    case result do
      {:ok, count} ->
        %{report | attachments: report.attachments + count}

      {:error, reason} ->
        skip(report, "outbox:#{outbox.agent_uid}/#{outbox.outbound_key}", reason)
    end
  end

  defp convert_attachments(root, agent_uid, attachments) do
    Enum.reduce_while(attachments, {:ok, [], []}, fn attachment, {:ok, converted, upserts} ->
      if is_binary(attachment["blob_ref"]) do
        {:cont, {:ok, [attachment | converted], upserts}}
      else
        with {:ok, local_path} <- legacy_attachment_path(root, agent_uid, attachment),
             {:ok, stored} <- Files.store({:file, local_path}) do
          name = attachment["name"] || Path.basename(local_path)
          path = Files.content_path("sent", stored.sha256, name)

          converted_attachment =
            attachment
            |> Map.drop(["agent_computer_path", "user_files_relative_path"])
            |> Map.merge(%{"blob_ref" => stored.sha256, "path" => path, "size" => stored.size})

          upsert = %{
            path: path,
            sha256: stored.sha256,
            source: "sent",
            content_type: attachment["mime_type"]
          }

          {:cont, {:ok, [converted_attachment | converted], [upsert | upserts]}}
        else
          error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, converted, upserts} -> {:ok, Enum.reverse(converted), Enum.reverse(upserts)}
      error -> error
    end
  end

  defp legacy_attachment_path(root, agent_uid, attachment) do
    relative =
      attachment["user_files_relative_path"] ||
        case attachment["agent_computer_path"] do
          path when is_binary(path) ->
            case String.split(path, "/#{agent_uid}/user-files/", parts: 2) do
              [_worker_root, relative] -> relative
              _invalid -> nil
            end

          _invalid ->
            nil
        end

    with {:ok, relative} <- Files.normalize_path(relative) do
      parts = [agent_uid, "user-files" | String.split(relative, "/")]

      Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, parent} ->
        path = Path.join(parent, part)

        case File.lstat(path) do
          {:ok, %{type: type}} when type in [:directory, :regular] -> {:cont, {:ok, path}}
          {:ok, %{type: type}} -> {:halt, {:error, {:not_a_regular_file, type}}}
          {:error, reason} -> {:halt, {:error, {path, reason}}}
        end
      end)
    end
  end

  defp legacy_jobs do
    Repo.across_tenants(fn ->
      Repo.all(
        from job in Job,
          where: not is_nil(job.legacy_directory_path),
          order_by: job.id
      )
    end)
  end

  # The legacy path goes only after every file of the script that can be
  # copied arrived. A script that this run could not find or copy keeps it,
  # so a run with the right volume, or after a transient storage error,
  # copies it later.
  defp import_job(root, %Job{} = job, report) do
    main = (local_dir = local_job_directory(root, job)) && Path.join(local_dir, "main.ts")

    case main && File.lstat(main) do
      {:ok, %{type: :regular}} ->
        skipped_before = length(report.skipped)
        report = import_folder(job.agent_uid, local_dir, job.drive_prefix, report)
        new_skips = Enum.take(report.skipped, length(report.skipped) - skipped_before)

        if Enum.all?(new_skips, fn {_path, reason} -> final_skip?(reason) end) do
          Repo.update_all(where(Job, id: ^job.id), set: [legacy_directory_path: nil])
        end

        %{report | jobs: report.jobs + 1}

      {:error, reason} when reason != :enoent ->
        skip(report, main, reason)

      _missing ->
        %{report | jobs_without_script: [job.id | report.jobs_without_script]}
    end
  end

  # The legacy path is absolute in the Worker's file system and lies inside
  # the Agent Home `<worker root>/<uid>`; the same Agent Home is
  # `<root>/<uid>` here.
  defp local_job_directory(root, %Job{agent_uid: agent_uid, legacy_directory_path: path}) do
    case String.split(path, "/" <> agent_uid <> "/", parts: 2) do
      [_worker_root, relative] -> Path.join([root, agent_uid, relative])
      [_path] -> nil
    end
  end

  defp import_folder(agent_uid, local_dir, prefix, report) do
    {entries, report} = collect(local_dir, "", report)

    {upserts, report} =
      Enum.reduce(entries, {[], report}, fn {local_path, relative, mode}, {upserts, report} ->
        path = if prefix == "", do: relative, else: prefix <> "/" <> relative

        case prepare(agent_uid, local_path, path, mode) do
          {:ok, upsert} -> {[upsert | upserts], report}
          :exists -> {upserts, report}
          {:error, reason} -> {upserts, skip(report, local_path, reason)}
        end
      end)

    upserts
    |> Enum.reverse()
    |> Enum.chunk_every(@commit_batch)
    |> Enum.reduce(report, fn batch, report ->
      case Files.commit(agent_uid, batch) do
        {:ok, %{files: files}} -> %{report | files: report.files + length(files)}
        {:error, reason} -> skip(report, local_dir, reason)
      end
    end)
  end

  defp prepare(agent_uid, local_path, path, mode) do
    with {:ok, path} <- Files.normalize_path(path),
         {:error, :not_found} <- Files.fetch(agent_uid, path),
         :ok <- within_transfer_limit(local_path),
         {:ok, %{sha256: sha256}} <- Files.store({:file, local_path}) do
      {:ok, %{path: path, sha256: sha256, source: "agent", mode: mode}}
    else
      {:ok, _file} -> :exists
      {:error, reason} -> {:error, reason}
    end
  end

  defp within_transfer_limit(local_path) do
    max_bytes = WorkerFiles.max_transfer_bytes()

    case File.stat(local_path) do
      {:ok, %{size: size}} when size > max_bytes -> {:error, {:file_too_large, size, max_bytes}}
      {:ok, _stat} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Lists regular files depth-first in name order. Symlinks are skipped, so a
  # link cannot pull a file from outside the Agent Home into the drive.
  defp collect(dir, relative, report) do
    {names, report} = list_dir(dir, report)

    names
    |> Enum.flat_map_reduce(report, fn name, report ->
      path = Path.join(dir, name)
      child = if relative == "", do: name, else: relative <> "/" <> name

      case File.lstat(path) do
        {:ok, %{type: :directory}} -> collect(path, child, report)
        {:ok, %{type: :regular, mode: mode}} -> {[{path, child, mode &&& 0o777}], report}
        {:ok, %{type: type}} -> {[], skip(report, path, {:not_a_regular_file, type})}
        {:error, reason} -> {[], skip(report, path, reason)}
      end
    end)
  end

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  # A missing directory is an Agent that never had such files. Any other
  # error is reported, so an unreadable Agent Home never looks empty.
  defp list_dir(dir, report) do
    case File.ls(dir) do
      {:ok, names} -> {Enum.sort(names), report}
      {:error, :enoent} -> {[], report}
      {:error, reason} -> {[], skip(report, dir, reason)}
    end
  end

  defp skip(report, path, reason), do: %{report | skipped: [{path, reason} | report.skipped]}

  # A symlink, a special file, or a file over the transfer limit is skipped on
  # every run; an unreadable entry or a storage error can succeed later.
  defp final_skip?({:not_a_regular_file, _type}), do: true
  defp final_skip?({:file_too_large, _size, _max_bytes}), do: true
  defp final_skip?(_reason), do: false
end
