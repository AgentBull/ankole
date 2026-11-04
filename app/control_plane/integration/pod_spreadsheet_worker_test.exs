Code.require_file("support/pod_document_worker.exs", __DIR__)

defmodule Ankole.PodSpreadsheetWorkerTest do
  use Ankole.DataCase, async: false

  alias Ankole.{Files, Kernel}
  alias Ankole.AgentWorkers.Config
  alias Ankole.Pod.Spreadsheets

  @moduletag sandbox: false, timeout: 240_000
  @moduletag :external

  setup do
    server = start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, previous} = Config.fetch()
    tenant_id = Repo.tenant_id!()
    on_exit(fn -> Config.put(Map.to_list(previous)) end)
    human = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Forecast Analyst"}).principal
    agent_uid = Ankole.PodDocumentWorker.start(port, human.uid)

    on_exit(fn ->
      Supervisor.terminate_child(Ankole.Supervisor, Ankole.PodDocumentWorker)

      Repo.with_tenant(tenant_id, fn ->
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent_uid)
      end)
    end)

    %{agent_uid: agent_uid, human: human}
  end

  test "real Agent file commands download pending Human edits and replace a spreadsheet", %{
    agent_uid: agent_uid,
    human: human
  } do
    actor = Ankole.PrincipalsFixtures.actor_fixture(agent_uid)

    file =
      Ankole.FilesFixtures.drive_file_fixture(
        agent_uid,
        "quarterly-forecast.xlsx",
        workbook("Q4 forecast")
      )

    replacement = workbook("Board-approved forecast")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(agent_uid, file.id, %{
        grants: [%{principal_uid: human.uid, role: "edit"}]
      })

    {:ok, %{revision: revision}} = Spreadsheets.bootstrap(actor, file.id)

    assert {:ok, %{revision: edited_revision}} =
             Spreadsheets.apply_op(Ankole.PrincipalsFixtures.actor_fixture(human.uid), file.id, %{
               base_revision: revision,
               client_id: "forecast-analyst",
               client_seq: 1,
               op: %{
                 "type" => "cell.set",
                 "sheet_id" => 1,
                 "cell" => "A2",
                 "input" => "Human pending forecast"
               }
             })

    {:ok, %{ops: [_]}} = Spreadsheets.bootstrap(actor, file.id)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:#{file.id}")

    for {path, bytes} <- [
          {"fixtures/spreadsheet-relay.ts", script()},
          {"fixtures/replacement.xlsx", replacement}
        ] do
      {:ok, stored} = Files.store(bytes)
      {:ok, _} = Files.commit(agent_uid, [Map.merge(stored, %{path: path, source: "agent"})])
    end

    {:ok, result} =
      Ankole.PodDocumentWorker.command(
        agent_uid,
        human.uid,
        "Replace the shared spreadsheet #{file.id} with the board-approved forecast",
        "ankole-files get fixtures/spreadsheet-relay.ts --output spreadsheet-relay.ts && " <>
          "bun spreadsheet-relay.ts " <> file.id,
        ~s({"downloaded_node")
      )

    assert result["downloaded_node"] == file.id
    assert result["replaced_node"] == file.id

    assert {:ok, _, downloaded} = Files.read(agent_uid, "results/before-replacement.xlsx")
    assert {:ok, %{plain_text: text}} = Kernel.spreadsheet_open(downloaded, [])
    assert text =~ "Q4 forecast"
    assert text =~ "Human pending forecast"

    assert {:ok, _, ^replacement} = Files.read(agent_uid, "quarterly-forecast.xlsx")

    assert {:ok, %{ops: [], file: %{object_id: object_id}}} =
             Spreadsheets.bootstrap(actor, file.id)

    assert result["replacement_object"] == object_id

    assert {:ok, %{changes: [%{kind: :reset}], reset_required: true}} =
             Spreadsheets.since(actor, file.id, edited_revision)

    assert Repo.get_by!(Ankole.Pod.FileCache, page_id: file.id).plain_text =~
             "Board-approved forecast"

    page_id = file.id
    assert_receive {:node_committed, ^page_id}, 5_000
  end

  defp workbook(label) do
    {:ok, %{doc_ref: document}} = Kernel.spreadsheet_create_blank("Quarterly forecast")

    {:ok, %{doc_ref: document}} =
      Kernel.spreadsheet_apply(
        document,
        %{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => label},
        []
      )

    {:ok, %{xlsx_bytes: bytes}} = Kernel.spreadsheet_export_xlsx(document)
    bytes
  end

  defp script do
    ~S"""
    const page = Bun.argv[2];
    async function files(...args) {
      const child = Bun.spawn(['ankole-files', ...args], {stdout: 'pipe', stderr: 'pipe'});
      const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      if (code !== 0) throw Error(err || out);
      return JSON.parse(out);
    }
    await files('get', 'fixtures/replacement.xlsx', '--output', 'replacement.xlsx');
    const before = await files('get', page, '--node', '--output', 'downloaded.xlsx');
    await files('put', 'downloaded.xlsx', 'results/before-replacement.xlsx');
    await files('put', 'replacement.xlsx', 'quarterly-forecast.xlsx');
    const after = await files('get', 'quarterly-forecast.xlsx', '--output', 'after.xlsx');
    console.log(JSON.stringify({downloaded_node: before.node_id, replaced_node: after.node_id, replacement_object: after.object_id}));
    """
  end
end
