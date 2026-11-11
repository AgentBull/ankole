Code.require_file("support/pod_document_worker.exs", __DIR__)

defmodule Ankole.PodOfficeWorkerTest do
  use Ankole.DataCase, async: false

  alias Ankole.{Files, Kernel}
  alias Ankole.AgentWorkers.Config
  alias Ankole.Pod.{OfficeFiles, Pages}

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

  test "real Agent file and office commands collaborate on Office Pages and render to the workspace",
       %{
         agent_uid: agent_uid,
         human: human
       } do
    actor = Ankole.PrincipalsFixtures.actor_fixture(agent_uid)
    human_actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)

    file =
      Ankole.FilesFixtures.drive_file_fixture(
        agent_uid,
        "quarterly-forecast.xlsx",
        workbook("Q4 forecast")
      )

    word_file =
      Ankole.FilesFixtures.drive_file_fixture(
        agent_uid,
        "exec-memo.docx",
        word_doc("Draft summary")
      )

    replacement = workbook("Board-approved forecast")

    for page_id <- [file.id, word_file.id] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(agent_uid, page_id, %{
          grants: [%{principal_uid: human.uid, role: "edit"}]
        })
    end

    {:ok, %{revision: revision}} = OfficeFiles.bootstrap(actor, file.id)

    assert {:ok, %{revision: edited_revision}} =
             OfficeFiles.apply_op(human_actor, file.id, %{
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

    {:ok, %{ops: [_]}} = OfficeFiles.bootstrap(actor, file.id)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:#{file.id}")

    for {path, bytes} <- [
          {"fixtures/office-relay.ts", script()},
          {"fixtures/replacement.xlsx", replacement}
        ] do
      {:ok, stored} = Files.store(bytes)
      {:ok, _} = Files.commit(agent_uid, [Map.merge(stored, %{path: path, source: "agent"})])
    end

    {:ok, result} =
      Ankole.PodDocumentWorker.command(
        agent_uid,
        human.uid,
        "Update the shared Office files #{file.id} and #{word_file.id}",
        "ankole-files get fixtures/office-relay.ts --output office-relay.ts && " <>
          "bun office-relay.ts " <> file.id <> " " <> word_file.id,
        ~s({"downloaded_node")
      )

    assert result["downloaded_node"] == file.id
    assert result["replaced_node"] == file.id
    assert result["png_magic"] == "89504e47"
    assert is_binary(result["converted_page_id"])

    assert {:ok, _, downloaded} = Files.read(agent_uid, "results/before-replacement.xlsx")
    assert {:ok, %{plain_text: text}} = Kernel.office_open(:spreadsheet, downloaded, [])
    assert text =~ "Q4 forecast"
    assert text =~ "Human pending forecast"

    assert {:ok, _, ^replacement} = Files.read(agent_uid, "quarterly-forecast.xlsx")

    assert {:ok, %{ops: [], file: %{object_id: object_id}}} =
             OfficeFiles.bootstrap(actor, file.id)

    assert result["replacement_object"] == object_id

    assert {:ok, %{changes: [%{kind: :reset}], reset_required: true}} =
             OfficeFiles.since(actor, file.id, edited_revision)

    assert Repo.get_by!(Ankole.Pod.PageSearchDocument, page_id: file.id).body_text =~
             "Board-approved forecast"

    assert {:ok, %{content: %{content: xml}}} =
             Pages.get(actor, result["converted_page_id"])

    assert xml =~ "Agent approved summary"

    page_id = file.id
    assert_receive {:node_committed, ^page_id}, 5_000
  end

  defp workbook(label) do
    {:ok, %{doc_ref: document}} = Kernel.office_create_blank(:spreadsheet, "Quarterly forecast")

    {:ok, %{doc_ref: document}} =
      Kernel.office_apply(
        document,
        %{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => label},
        [],
        nil
      )

    {:ok, %{bytes: bytes}} = Kernel.office_export(document)
    bytes
  end

  defp word_doc(paragraph_text) do
    {:ok, %{doc_ref: document}} = Kernel.office_create_blank(:word, "Exec memo")

    {:ok, %{doc_ref: document}} =
      Kernel.office_apply_commands(
        document,
        [
          %{
            "command" => "text.insert",
            "params" => %{"text" => paragraph_text, "paragraphs" => true}
          }
        ],
        ""
      )

    {:ok, %{bytes: bytes}} = Kernel.office_export(document)
    bytes
  end

  defp script do
    ~S"""
    const [sheetPage, wordPage] = Bun.argv.slice(2);
    async function run(bin, ...args) {
      const child = Bun.spawn([bin, ...args], {stdout: 'pipe', stderr: 'pipe'});
      const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      if (code !== 0) throw Error(err || out);
      return JSON.parse(out);
    }
    await run('ankole-files', 'get', 'fixtures/replacement.xlsx', '--output', 'replacement.xlsx');
    const before = await run('ankole-files', 'get', sheetPage, '--node', '--output', 'downloaded.xlsx');
    await run('ankole-files', 'put', 'downloaded.xlsx', 'results/before-replacement.xlsx');
    await run('ankole-files', 'put', 'replacement.xlsx', 'quarterly-forecast.xlsx');
    const after = await run('ankole-files', 'get', 'quarterly-forecast.xlsx', '--output', 'after.xlsx');

    const inspected = await run('ankole-pod', 'office.inspect', JSON.stringify({id: wordPage, scope: 'summary'}));
    const applied = await run('ankole-pod', 'office.apply', JSON.stringify({
      id: wordPage,
      base_revision: inspected.revision,
      commands: [{
        command: 'text.insert',
        params: {text: 'Agent approved summary', paragraphs: true}
      }]
    }));
    const rendered = await run('ankole-pod', 'office.render', '--to', 'rendered-memo.png', JSON.stringify({id: wordPage, page: 1}));
    const pngBytes = new Uint8Array(await Bun.file(rendered.path).arrayBuffer());
    const pngMagic = Buffer.from(pngBytes.subarray(0, 4)).toString('hex');
    const converted = await run('ankole-pod', 'office.to_document', JSON.stringify({id: wordPage}));

    console.log(JSON.stringify({
      downloaded_node: before.node_id,
      replaced_node: after.node_id,
      replacement_object: after.object_id,
      word_revision: applied.revision,
      png_magic: pngMagic,
      converted_page_id: converted.page.id
    }));
    """
  end
end
