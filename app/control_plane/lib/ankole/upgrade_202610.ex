defmodule Ankole.Upgrade202610 do
  @moduledoc """
  Temporary data and file upgrade steps for the 2026-10 release.

  Mix and Release run `run/0` after schema migrations. To repeat only the
  database steps, run `mix run --no-start -e 'Ankole.Upgrade202610.run()'`
  with the original encryption key and every control-plane replica stopped.

  `import_agent_home/1` copies installed Skills, Automation Job scripts, and
  unsent legacy Delivery attachments from a pooled Worker `/agents` directory
  into Agent drives without replacing existing drive files.

  Remove this file, its Mix alias, its Release call, and
  `files.importAgentHomeClaim` when every supported direct-upgrade origin
  includes these steps and upgrade checks find no old identity-provider scope,
  shared Slack/Teams key, missing application identity, legacy Skill directory,
  `legacy_directory_path`, or legacy Delivery attachment path.
  """

  import Bitwise
  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Files
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Tenants.Tenant
  alias Ankole.WorkerFiles

  @tenant_schema_version 20_261_009_120_000
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

  @doc false
  def migrate(repo, paths, :up, opts) do
    migrated = Ecto.Migrator.run(repo, paths, :up, opts)

    # A partial schema migration can stop before tenant ownership exists.
    if repo == Repo and @tenant_schema_version in Ecto.Migrator.migrated_versions(repo, opts),
      do: run()

    migrated
  end

  @doc "Runs the temporary data steps without starting the control-plane application."
  @spec run() :: :ok
  def run do
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _apps} = Application.ensure_all_started(:req)

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Repo.without_tenant(fn ->
          migrate_identity_provider_configurations()

          with_processes(
            [{Registry, []}, {Phoenix.PubSub.Supervisor, [name: Ankole.PubSub]}, {Cache, []}],
            &migrate_binding_configurations/0
          )
        end)
      end)

    :ok
  end

  # Stop only the processes this invocation starts. Mix can start the full
  # application after migration, as ecto.setup does when it runs seeds.
  defp with_processes([], fun), do: fun.()

  defp with_processes([{module, opts} | rest], fun) do
    case module.start_link(opts) do
      {:ok, pid} ->
        try do
          with_processes(rest, fun)
        after
          GenServer.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        with_processes(rest, fun)

      {:error, reason} ->
        raise "failed to start #{inspect(module)} for the 2026-10 upgrade: #{inspect(reason)}"
    end
  end

  # Scope participates in key derivation. Decrypt, seal for the new scope and
  # delete the old row in one transaction; copying ciphertext cannot work.
  defp migrate_identity_provider_configurations do
    case Repo.transact(fn repo ->
           rows =
             repo.all(
               from config in SiteConfig,
                 where:
                   config.scope == "global" and fragment("?->>'type' = 'cipher'", config.value) and
                     (like(config.key, "principals.identity_providers.%") or
                        like(config.key, "principals.entra_id.graph_subscriptions.%")),
                 lock: "FOR UPDATE"
             )

           # A later run remains a no-op after the original tenant is renamed.
           tenant = if rows != [], do: repo.get_by!(Tenant, slug: "default")
           scope = if tenant, do: "tenant:" <> tenant.id

           Enum.reduce_while(rows, {:ok, :migrated}, fn row, result ->
             case migrate_identity_provider_row(repo, row, tenant, scope) do
               :ok -> {:cont, result}
               {:error, reason} -> {:halt, {:error, {row.key, reason}}}
             end
           end)
         end) do
      {:ok, :migrated} -> :ok
      {:error, reason} -> raise "identity provider tenant migration failed: #{inspect(reason)}"
    end
  end

  defp migrate_identity_provider_row(
         _repo,
         %{value: %{"type" => "cipher", "value" => cipher}} = row,
         tenant,
         scope
       ) do
    with {:ok, value} <- Crypto.unseal(cipher, "global", row.key),
         {:ok, resealed} <- Crypto.seal(value, scope, row.key),
         {:ok, _} <-
           Repo.with_tenant(tenant.id, fn ->
             Ankole.Ash.create(AppConfig, :import_envelope, %{
               scope: scope,
               key: row.key,
               value: %{"type" => "cipher", "value" => resealed}
             })
           end) do
      {:ok, _deleted} = Ankole.Ash.destroy(row, :remove)

      :ok
    end
  end

  # One transaction covers every reference to each shared binding key.
  defp migrate_binding_configurations do
    {:ok, snapshot} = Ankole.Plugins.Registry.prepare_snapshot()
    specs = Map.values(snapshot.discovered)

    :ok =
      Registry.replace_declarations(
        :plugins,
        Enum.flat_map(specs, & &1.app_config_definitions),
        Enum.flat_map(specs, & &1.app_config_patterns)
      )

    # Only discovery crosses tenants. Each binding write runs in its tenant.
    bindings =
      Repo.across_tenants(fn ->
        Repo.all(from binding in Binding, where: binding.adapter in ["slack", "teams"])
      end)

    bindings
    |> Enum.filter(fn binding ->
      binding.config_ref == "app-config://#{config_module(binding).chat_config_key(binding.name)}"
    end)
    |> Enum.group_by(& &1.config_ref)
    |> Enum.each(fn {"app-config://" <> old_key, bindings} ->
      case Repo.transact(fn repo -> migrate_shared_key(repo, old_key, bindings) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> raise "binding configuration migration failed: #{inspect(reason)}"
      end
    end)

    backfill_application_identities(specs)
  end

  defp migrate_shared_key(repo, old_key, bindings) do
    with {:ok, config} <- AppConfigure.get_global_by_key_in_tx(repo, old_key),
         :ok <- migrate_bindings(repo, bindings, config) do
      old_ref = "app-config://#{old_key}"

      remaining? =
        Repo.across_tenants(fn ->
          repo.exists?(from binding in Binding, where: binding.config_ref == ^old_ref)
        end)

      unless remaining? do
        repo.delete_all(
          from row in SiteConfig, where: row.scope == "global" and row.key == ^old_key
        )
      end

      {:ok, :ok}
    else
      :error -> {:error, {:missing_binding_configuration, old_key}}
      {:error, _reason} = error -> error
    end
  end

  defp migrate_bindings(repo, bindings, config) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      new_key = config_module(binding).binding_config_key(binding.agent_uid, binding.name)

      result =
        Repo.with_tenant(binding.tenant_id, fn ->
          with :ok <- ensure_destination(repo, new_key, config),
               {:ok, _write} <- AppConfigure.put_global_by_key_in_tx(repo, new_key, config),
               {:ok, _binding} <-
                 repo.update(
                   Ecto.Changeset.change(binding, config_ref: "app-config://#{new_key}")
                 ) do
            :ok
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_destination(repo, key, config) do
    case AppConfigure.get_global_by_key_in_tx(repo, key) do
      :error -> :ok
      {:ok, ^config} -> :ok
      {:ok, _different} -> {:error, {:binding_configuration_key_conflict, key}}
      {:error, _reason} = error -> error
    end
  end

  # Resolve credentials outside transactions. Report the owning tenant and key
  # on failure so the operator can repair the configuration and repeat the command.
  defp backfill_application_identities(specs) do
    declarations = Enum.flat_map(specs, & &1.adapter_declarations)
    bindings = Repo.across_tenants(fn -> Repo.all(Binding) end)

    Enum.each(bindings, fn binding ->
      declaration =
        Enum.find(
          declarations,
          &(&1[:contract_id] == "signals.adapter" and &1[:id] == binding.adapter)
        )

      if declaration do
        "app-config://" <> key = binding.config_ref
        backfill_identity(binding.tenant_id, "global", key, declaration[:config_module], :binding)
      end
    end)

    Enum.each(Repo.all(Tenant), fn tenant ->
      Repo.with_tenant(tenant.id, fn ->
        {:ok, providers} =
          AppConfigure.get_tenant_by_key_in_tx(Repo, "principals.identity_providers.active")

        Enum.each(providers, fn provider ->
          declaration =
            Enum.find(
              declarations,
              &(&1[:contract_id] == "principals.identity_provider" and
                  &1[:id] == provider["adapter_id"])
            )

          if declaration,
            do:
              backfill_identity(
                tenant.id,
                "tenant:" <> tenant.id,
                provider["config_key"],
                declaration[:module],
                :identity_provider
              )
        end)
      end)
    end)

    :ok
  end

  defp backfill_identity(tenant_id, scope, key, module, source) do
    row =
      Repo.with_tenant(tenant_id, fn ->
        Repo.get_by(AppConfig.for_scope(scope), scope: scope, key: key)
      end)

    if row && not Map.has_key?(row.value, "platform_application") do
      result =
        with {:ok, definition} <- Registry.require_key(key),
             {:ok, config} <- AppConfigure.Codec.load(definition, scope, key, row.value),
             {:ok, application} <- Bindings.resolve_platform_application(module, config, source) do
          Repo.with_tenant(tenant_id, fn ->
            Repo.transact(&record_identity_in_tx(&1, row, config, application))
          end)
        end

      case result do
        {:ok, :recorded} ->
          :ok

        {:error, reason} ->
          raise "platform application migration failed for tenant #{tenant_id}, configuration #{key}: #{inspect(reason)}; repair the configuration and rerun mix ecto.migrate or Release.migrate"
      end
    end
  end

  defp record_identity_in_tx(repo, row, config, application) do
    schema = AppConfig.for_scope(row.scope)

    locked =
      repo.one(
        from config in schema,
          where: config.scope == ^row.scope and config.key == ^row.key,
          lock: "FOR UPDATE"
      )

    if locked.value == row.value do
      with :ok <- Bindings.validate_platform_application_in_tx(repo, application),
           :ok <-
             Bindings.record_platform_application_in_tx(
               repo,
               {config, row.scope, row.key},
               application
             ),
           do: {:ok, :recorded}
    else
      {:error, :configuration_changed}
    end
  end

  defp config_module(%Binding{adapter: "slack"}), do: Ankole.Plugins.SlackAdapter.Config
  defp config_module(%Binding{adapter: "teams"}), do: Ankole.Plugins.Microsoft365Adapter.Config

  @doc """
  Copies the files that Agents kept in their Agent Homes under `agents_root`
  into their drives, and prints a report.
  """
  @spec import_agent_home(Path.t()) :: report()
  def import_agent_home(agents_root) when is_binary(agents_root) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok = Application.ensure_loaded(:ankole)
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)

    {:ok, report, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Repo.without_tenant(fn ->
          root = Path.expand(agents_root)

          unless File.dir?(root) do
            raise "Agent Home import failed: #{inspect({:not_a_directory, root})}"
          end

          report = import_agent_homes(root)
          IO.puts(format_report(report))
          report
        end)
      end)

    report
  end

  defp import_agent_homes(root) do
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
      Enum.reduce(legacy_intents(), report, fn intent, report ->
        Repo.with_tenant(intent.tenant_id, fn -> import_attachments(root, intent, report) end)
      end)

    %{
      report
      | jobs_without_script: Enum.reverse(report.jobs_without_script),
        skipped: Enum.reverse(report.skipped)
    }
  end

  defp format_report(report) do
    lines =
      [
        "Imported #{report.files} files for #{report.agents} Agents and #{report.jobs} Automation Job scripts.",
        "Migrated #{report.attachments} pending intent attachments."
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

  defp legacy_intents do
    Repo.across_tenants(fn ->
      Repo.all(
        from intent in Intent,
          where: intent.status != :sent,
          where:
            fragment(
              "jsonb_path_exists(?, '$.attachments[*].user_files_relative_path') OR jsonb_path_exists(?, '$.attachments[*].agent_computer_path')",
              intent.payload,
              intent.payload
            ),
          order_by: [intent.agent_uid, intent.binding_name, intent.outbound_key]
      )
    end)
  end

  defp import_attachments(root, intent, report) do
    # The upgrade runs with dispatch stopped. The row lock also makes repeat
    # imports safe and keeps a completed send's audit payload unchanged.
    result =
      with {:ok, attachments, upserts} <-
             convert_attachments(root, intent.agent_uid, intent.payload["attachments"] || []) do
        Repo.transact(fn repo ->
          current =
            Intent
            |> where(
              [entry],
              entry.agent_uid == ^intent.agent_uid and entry.binding_name == ^intent.binding_name and
                entry.outbound_key == ^intent.outbound_key
            )
            |> lock("FOR UPDATE")
            |> repo.one!()

          if current.status == :sent do
            {:ok, 0}
          else
            with true <- current.payload == intent.payload || {:error, :intent_changed},
                 {:ok, _result} <-
                   Files.commit(repo, current.agent_uid, Enum.uniq_by(upserts, & &1.path), []),
                 {:ok, _row} <-
                   Ankole.Ash.update(current, :import_attachments, %{
                     payload: Map.put(current.payload, "attachments", attachments)
                   }),
                 {:ok, _intent} <-
                   Ankole.Conversations.Delivery.commit_in_tx(repo, %{
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
        skip(report, "intent:#{intent.agent_uid}/#{intent.outbound_key}", reason)
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
          {:ok, _} =
            Repo.transact(fn repo ->
              current =
                repo.one!(from(row in Job, where: row.id == ^job.id, lock: "FOR UPDATE"),
                  lock_identity: {"automation_jobs", job.id}
                )

              Ankole.Ash.update(current, :finish_script_import, %{})
            end)
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
