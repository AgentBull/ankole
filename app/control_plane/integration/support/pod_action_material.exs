defmodule Ankole.PodActionMaterial do
  @moduledoc false
  alias Ankole.Pod.{Bases, Pages}

  def seed(agent, parent, repository, state_path) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(agent.uid)
    {:ok, base} = Pages.create(actor, %{type: "base", title: "Import rows", parent_id: parent.id})
    {:ok, source} = Bases.create_table(actor, base.id, %{name: "Source"})
    {:ok, target} = Bases.create_table(actor, base.id, %{name: "Imported"})
    source_key = hd(Bases.fields(source.id)).id
    target_key = hd(Bases.fields(target.id)).id
    {:ok, _} = Bases.configure_table(actor, target.id, %{unique_field_ids: [target_key]})

    {:ok, _} =
      Bases.write_records(actor, source.id, %{
        creates: for(n <- 1..100, do: %{data: %{source_key => "Record #{n}"}})
      })

    {:ok, page} =
      Pages.create(actor, %{type: "applet", title: "Background import", parent_id: parent.id})

    output = Path.join(Path.dirname(state_path), "action-applets")

    {log, 0} =
      System.cmd(
        "bun",
        ["app/webapps/integration/pod-browser/build-actions.ts", target.id, output],
        cd: repository,
        stderr_to_stdout: true
      )

    IO.write(log)
    manifests = output |> Path.join("manifests.json") |> File.read!() |> Torque.decode!()

    files =
      Map.new(manifests, fn {version, entries} ->
        files =
          Enum.map(entries, fn entry ->
            {:ok, blob} = Ankole.Files.store({:file, entry["local_path"]})

            Map.merge(blob, %{
              path: entry["path"],
              source_path: "_pod/actions/#{version}/#{entry["path"]}",
              content_type: entry["content_type"]
            })
          end)

        {:ok, _} =
          Ankole.Files.commit(
            agent.uid,
            Enum.map(files, &Map.merge(&1, %{path: &1.source_path, source: "agent"}))
          )

        {version, files}
      end)

    {:ok, _} = Ankole.Pod.Files.publish(actor, page.id, 0, files["complete"])

    {:ok, job} =
      Ankole.AutomationJobs.create_applet_job(actor, page.id, "sync", %{
        authorization_kind: "service",
        config: %{
          source: source.id,
          target: target.id,
          source_key: source_key,
          target_key: target_key
        }
      })

    %{
      page_id: page.id,
      job_id: job.id,
      target_table_id: target.id,
      complete_files: files["complete"],
      missing_files: files["missing"]
    }
  end
end
