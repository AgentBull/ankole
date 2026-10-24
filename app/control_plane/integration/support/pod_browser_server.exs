# Dedicated real-PostgreSQL browser fixture. Run with MIX_ENV=test and its own
# MIX_TEST_PARTITION. No browser request bypasses authentication or a domain owner.
partition = System.get_env("MIX_TEST_PARTITION", "")

unless Mix.env() == :test and
         (partition == "pod_browser" or String.starts_with?(partition, "pod_browser_")) do
  raise "Use MIX_ENV=test and a pod_browser test partition for the Pod browser fixture"
end

port = String.to_integer(System.get_env("POD_BROWSER_PORT", "4000"))

endpoint = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)

Application.put_env(
  :ankole,
  AnkoleWeb.Endpoint,
  Keyword.merge(endpoint,
    server: true,
    check_origin: ["http://127.0.0.1:#{port}"],
    http: Keyword.merge(Keyword.get(endpoint, :http, []), ip: {127, 0, 0, 1}, port: port)
  )
)

Application.put_env(:ankole, AnkoleWeb.Assets, dev_server: nil)
# Long-lived browser channels need the production checkout lifecycle. A Sandbox
# connection belongs to its channel process until that process exits.
Application.put_env(
  :ankole,
  Ankole.Repo,
  Application.fetch_env!(:ankole, Ankole.Repo)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)
)

{:ok, _} = Application.ensure_all_started(:ankole)
Logger.configure(level: :warning)

alias Ankole.{AuthZ, BrowserSessions, Repo}

# This dedicated test database defaults to Chinese labels for its browser selectors.
{:ok, original_site_locale} =
  Ankole.AppConfigure.get(Ankole.I18n.Config.default_locale_definition(), scope: :global)

{:ok, _} =
  Ankole.AppConfigure.put_global_by_key(
    "i18n.default_locale",
    System.get_env("POD_BROWSER_LOCALE", "zh-Hans-CN")
  )

System.at_exit(fn _ ->
  Ankole.AppConfigure.put_global_by_key("i18n.default_locale", original_site_locale)
end)

alias Ankole.Pod.{Database, Pages}
alias AnkoleWeb.Session, as: WebSession

tenant = Ankole.DataCase.create_tenant()
Repo.put_tenant_id(tenant.id)
origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: port}, tenant)

configured =
  Application.fetch_env!(:ankole, AnkoleWeb.Endpoint) |> Keyword.put(:check_origin, [origin])

Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)
:ok = AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, configured}], [])
{:ok, _} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

limits = %{
  "local_rows" => 5000,
  "local_bytes" => 5_000_000,
  "query_rows" => 1000,
  "record_bytes" => 1_000_000,
  "group_count" => 1000,
  "statement_timeout_ms" => 5000
}

{:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.database.limits", limits)

owner_account = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Browser owner"})
member_account = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Browser member"})
viewer_account = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Browser viewer"})
owner = owner_account.principal
member = member_account.principal
viewer = viewer_account.principal

# These credentials belong only to this isolated test database. Browser tests
# can use the real password form instead of injecting authentication cookies.
{:ok, _} = Ankole.IdentityProviders.save_provider("pod-browser-local", "local", %{}, true)
test_password = "Browser-" <> AnkoleWeb.Session.opaque_token()

for human <- [owner, member, viewer] do
  {:ok, _} =
    Ankole.IdentityProviders.LocalPassword.set_local_password(human.uid, test_password, false)
end

other_tenant = Ankole.DataCase.create_tenant()

other_pod =
  Repo.with_tenant(other_tenant.id, fn ->
    {:ok, _} = Ankole.IdentityProviders.save_provider("pod-browser-local", "local", %{}, true)
    account = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Other workspace owner"})

    {:ok, _} =
      Ankole.IdentityProviders.LocalPassword.set_local_password(
        account.principal.uid,
        test_password,
        false
      )

    {:ok, page} =
      Pages.create(account.principal.uid, %{
        title: "Other workspace login",
        private_owner_uid: account.principal.uid
      })

    %{
      base_url: AnkoleWeb.PodURL.origin(%{scheme: :http, port: port}, other_tenant),
      page_id: page.id,
      uid: account.principal.uid,
      email: account.human_user.email,
      password: test_password
    }
  end)

Repo.put_tenant_id(tenant.id)

agent =
  Ankole.PrincipalsFixtures.agent_fixture(%{display_name: "Browser content Agent"}).principal

# Real preference APIs use this synthetic profile; the browser fixture never runs its model.
model_provider_id = "pod-browser-model-" <> tenant.id

{:ok, _} =
  Ankole.AIGateway.ProviderConfigs.create_provider(%{
    provider_id: model_provider_id,
    provider_kind: "openai",
    base_url: "http://127.0.0.1:0/v1",
    credential_pool: %{
      "entries" => [%{"label" => "Browser fixture", "api_key" => "fixture-unused"}]
    }
  })

{:ok, _} =
  Ankole.AIAgent.ModelProfiles.put_model_profile(agent.uid, "careful", %{
    description: "Careful browser fixture analysis",
    provider_id: model_provider_id,
    model: "fixture-model"
  })

{:ok, _} =
  AuthZ.create_permission_grant(%{
    principal_uid: owner.uid,
    resource_pattern: "**",
    action: "update"
  })

{:ok, report} = Pages.create(owner.uid, %{title: "Browser report"})

{:ok, data_page} =
  Pages.create(owner.uid, %{type: "database", title: "Browser sales", parent_id: report.id})

{:ok, table} = Database.create_table(owner.uid, data_page.id, %{name: "Sales"})
{:ok, amount} = Database.create_field(owner.uid, table.id, %{name: "Amount", type: "number"})

{:ok, status} =
  Database.create_field(owner.uid, table.id, %{
    name: "Status",
    type: "select",
    config: %{
      "options" => [%{"id" => "new", "name" => "New"}, %{"id" => "done", "name" => "Done"}]
    }
  })

{:ok, _} =
  Database.write_records(owner.uid, table.id, %{
    creates: [%{data: %{amount.id => 10, status.id => "new"}}]
  })

{:ok, applet} =
  Pages.create(owner.uid, %{type: "applet", title: "Browser tracker", parent_id: report.id})

{:ok, _} =
  Ankole.Pod.PagesFixtures.set_sharing(owner.uid, report.id, %{
    inherit_permissions: false,
    grants: [
      %{principal_uid: owner.uid, role: "manage"},
      %{principal_uid: member.uid, role: "edit"},
      %{principal_uid: viewer.uid, role: "view"},
      %{principal_uid: agent.uid, role: "edit"}
    ]
  })

cookies = fn principal ->
  session_opts =
    Plug.Session.init(AnkoleWeb.SessionCookies.session_options())

  conn =
    Plug.Test.conn(:get, origin <> "/")
    |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(session_opts)
    |> Plug.Conn.fetch_session()

  {:ok, conn, transaction} = WebSession.begin_login(conn, :pod, %{})

  {:ok, _} =
    BrowserSessions.bind_provider(
      WebSession.browser_reference(conn),
      transaction.id,
      "pod-browser-test"
    )

  {:ok, conn, _} =
    WebSession.complete_login(conn, transaction.id, %{
      "principal_uid" => principal.uid,
      "access_version" => principal.access_version,
      "provider_id" => "pod-browser-test",
      "external_id" => principal.uid
    })

  conn = Plug.Conn.send_resp(conn, 200, "fixture")

  Enum.map(conn.resp_cookies, fn {name, opts} ->
    scope =
      if domain = opts[:domain],
        do: %{domain: "." <> String.trim_leading(domain, "."), path: "/"},
        else: %{url: origin}

    %{
      name: name,
      value: opts.value,
      httpOnly: true,
      secure: false,
      sameSite: "Lax"
    }
    |> Map.merge(scope)
  end)
end

state_path = System.fetch_env!("POD_BROWSER_STATE_PATH")
File.mkdir_p!(Path.dirname(state_path))

repository = Path.expand("../../../..", __DIR__)
applet_output = Path.join(Path.dirname(state_path), "applets")

{build_output, 0} =
  System.cmd(
    "bun",
    [
      "app/webapps/integration/pod-browser/build.ts",
      table.id,
      amount.id,
      status.id,
      applet_output
    ],
    cd: repository,
    stderr_to_stdout: true
  )

IO.write(build_output)
manifests = Path.join(applet_output, "manifests.json") |> File.read!() |> Torque.decode!()

publish_files =
  Map.new(manifests, fn {version, entries} ->
    files =
      Enum.map(entries, fn entry ->
        {:ok, stored} = Ankole.Files.store({:file, entry["local_path"]})
        %{path: entry["path"], sha256: stored.sha256, content_type: entry["content_type"]}
      end)

    {:ok, _} =
      Ankole.Files.commit(
        agent.uid,
        Enum.map(
          files,
          &Map.merge(&1, %{path: "_pod/browser/#{version}/" <> &1.path, source: "agent"})
        )
      )

    {version, files}
  end)

candidates = Enum.map(publish_files["v2"], &%{&1 | path: "src/candidate-v2/" <> &1.path})
{:ok, _} = Ankole.Pod.Files.publish(agent.uid, applet.id, 0, publish_files["v1"] ++ candidates)

{:ok, runtime_test_applet} =
  Ankole.Pod.Pages.create(agent.uid, %{
    type: "applet",
    title: "Runtime recovery applet",
    parent_id: report.id
  })

{:ok, _} =
  Ankole.Pod.Files.publish(
    agent.uid,
    runtime_test_applet.id,
    0,
    publish_files["v1"] ++ candidates
  )

# This independent workspace uses the production backend runtime. It does not
# depend on the other stories' table edits, access revocation, or publication.
{:ok, backend_report} = Pages.create(owner.uid, %{title: "Sample operations"})

{:ok, _} =
  Ankole.Pod.PagesFixtures.set_sharing(owner.uid, backend_report.id, %{
    inherit_permissions: false,
    grants: [
      %{principal_uid: owner.uid, role: "manage"},
      %{principal_uid: member.uid, role: "edit"},
      %{principal_uid: viewer.uid, role: "view"},
      %{principal_uid: agent.uid, role: "edit"}
    ]
  })

{:ok, backend_database} =
  Pages.create(owner.uid, %{
    type: "database",
    title: "Sample inventory",
    parent_id: backend_report.id
  })

{:ok, inventory} = Database.create_table(owner.uid, backend_database.id, %{name: "Inventory"})
inventory_name = Enum.find(Database.fields(inventory.id), & &1.is_primary)

{:ok, stock} =
  Database.create_field(owner.uid, inventory.id, %{name: "Available", type: "number"})

{:ok, %{records: [sample]}} =
  Database.write_records(owner.uid, inventory.id, %{
    creates: [%{data: %{inventory_name.id => "Cedar sample kit", stock.id => 5}}]
  })

{:ok, backend_applet} =
  Pages.create(owner.uid, %{
    type: "applet",
    title: "Sample reservations",
    parent_id: backend_report.id
  })

backend_output = Path.join(Path.dirname(state_path), "backend-applets")

{backend_build_output, 0} =
  System.cmd(
    "bun",
    [
      "app/webapps/integration/pod-browser/build-backend.ts",
      inventory.id,
      stock.id,
      sample.id,
      backend_output
    ],
    cd: repository,
    stderr_to_stdout: true
  )

IO.write(backend_build_output)

backend_manifests =
  Path.join(backend_output, "manifests.json") |> File.read!() |> Torque.decode!()

backend_files =
  Map.new(backend_manifests, fn {version, entries} ->
    # The browser owner publishes v2; its new digests must belong to that caller.
    publisher_uid = if version == "v2", do: owner.uid, else: agent.uid

    files =
      Enum.map(entries, fn entry ->
        {:ok, stored} = Ankole.Files.store({:file, entry["local_path"]})
        %{path: entry["path"], sha256: stored.sha256, content_type: entry["content_type"]}
      end)

    {:ok, _} =
      Ankole.Files.commit(
        publisher_uid,
        Enum.map(
          files,
          &Map.merge(&1, %{path: "_pod/backend/#{version}/" <> &1.path, source: "agent"})
        )
      )

    {version, files}
  end)

{:ok, _} = Ankole.Pod.Files.publish(agent.uid, backend_applet.id, 0, backend_files["v1"])

{:ok, _} =
  Ankole.Pod.Documents.write(
    owner.uid,
    backend_report.id,
    0,
    "<page><p>Reserve samples before your supplier review. Everyone works from the same inventory.</p><embed ref=\"#{backend_applet.id}\"/></page>"
  )

# Seed UI materials through the Conversation commit owner. This fixture does
# not claim a model run; the dedicated real-LLM suite checks that boundary.
conversation_id = Ankole.Ecto.UUIDv7.autogenerate()
input_id = Ankole.Ecto.UUIDv7.autogenerate()

{:ok, _conversation} =
  Ankole.Conversations.create(owner.uid, %{
    conversation_id: conversation_id,
    agent_uid: agent.uid,
    message_id: input_id,
    text: "Keep the browser research results."
  })

input = Repo.get_by!(Ankole.Signals.Signal, message_id: input_id)
chat_text = "Browser chat findings. [Open the report](ankole:page/#{report.id})."

attachment =
  Ankole.FilesFixtures.sent_attachment_fixture(
    agent.uid,
    "browser-evidence.txt",
    "Original browser research evidence.",
    "text/plain"
  )

{:ok, %{messages: [chat_message]}} =
  Repo.transact(fn ->
    with :ok <- Ankole.Sessions.Queue.lock_session_in_tx(agent.uid, input.session_id),
         {:ok, target} <- Ankole.Conversations.Target.for_reply(input),
         {:ok, result} <-
           Ankole.Conversations.post_in_tx(target, %Ankole.Conversations.Statement{
             signal: input,
             completion: %{final_text: chat_text, clarify_prompt: nil, attachments: [attachment]}
           }),
         {:ok, _input} <-
           Ankole.Sessions.Queue.mark_event_completed_in_tx(
             input,
             DateTime.utc_now(:microsecond)
           ) do
      {:ok, result}
    end
  end)

# This separate idle Conversation is intentionally deleted by the cross-window
# local-draft recovery story. The findings Conversation remains for its own test.

# These are committed UI materials, not model outputs. Runtime input/retry and
# real-provider acceptance are covered separately by their corresponding suites.
control_material = fn text ->
  id = Ankole.Ecto.UUIDv7.autogenerate()

  {:ok, reply} =
    Repo.transact(fn ->
      with {:ok, %{event: event}} <-
             Ankole.Conversations.create_in_tx(owner.uid, %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: Ankole.Ecto.UUIDv7.autogenerate(),
               text: text
             }),
           {:ok, %{messages: [reply]}} <-
             Ankole.ConversationsFixtures.post_statement_in_tx(
               event,
               "Completed UI material.\n\n```typescript\nconst total = 42\nconsole.log(total)\n```"
             ),
           {:ok, _} <-
             Ankole.Sessions.Queue.mark_event_completed_in_tx(
               event,
               DateTime.utc_now(:microsecond)
             ),
           do: {:ok, reply}
    end)

  {id, reply.id}
end

{chat_controls_conversation_id, chat_controls_reply_id} =
  control_material.("Original completed edit request")

{chat_regenerate_conversation_id, chat_regenerate_reply_id} =
  control_material.("Original completed regenerate request")

# This failure uses the real Main terminal transition without contacting a
# model Provider. The browser can exercise the actual retry mutation separately.
chat_failed_conversation_id = Ankole.Ecto.UUIDv7.autogenerate()

{:ok, failed_detail} =
  Ankole.Conversations.create(owner.uid, %{
    conversation_id: chat_failed_conversation_id,
    agent_uid: agent.uid,
    message_id: Ankole.Ecto.UUIDv7.autogenerate(),
    text: "Original failed reply request",
    model_profile: "careful"
  })

failed_input = Repo.get_by!(Ankole.Signals.Signal, conversation_id: chat_failed_conversation_id)
failed_key = %{agent_uid: agent.uid, session_id: failed_detail.session_id}

{:ok, %Ankole.Sessions.Run{} = failed_run} =
  Ankole.Sessions.Admission.admit(failed_key, failed_input)

{:ok, {:preparing, failed_run}} = Ankole.Sessions.Model.prepare(failed_run)

{:ok, %{posted: %{messages: [failed_notice]}}} =
  Ankole.Sessions.Run.finalize(failed_run, :dead_letter, %{"code" => "browser_fixture_failure"})

history_conversation_id = Ankole.Ecto.UUIDv7.autogenerate()

{:ok, :history_material_ready} =
  Repo.transact(
    fn ->
      {:ok, %{event: first}} =
        Ankole.Conversations.create_in_tx(owner.uid, %{
          conversation_id: history_conversation_id,
          agent_uid: agent.uid,
          message_id: Ankole.Ecto.UUIDv7.autogenerate(),
          text: "History item 0001"
        })

      {:ok, _} =
        Ankole.Sessions.Queue.mark_event_completed_in_tx(
          first,
          DateTime.utc_now(:microsecond)
        )

      for sequence <- 2..1006 do
        {:ok, %{event: event}} =
          Ankole.Conversations.post_in_tx(owner.uid, history_conversation_id, %{
            message_id: Ankole.Ecto.UUIDv7.autogenerate(),
            text: "History item " <> String.pad_leading(Integer.to_string(sequence), 4, "0")
          })

        {:ok, _} =
          Ankole.Sessions.Queue.mark_event_completed_in_tx(
            event,
            DateTime.utc_now(:microsecond)
          )
      end

      {:ok, :history_material_ready}
    end,
    timeout: 60_000
  )

recovery_conversation_id = Ankole.Ecto.UUIDv7.autogenerate()
recovery_message_id = Ankole.Ecto.UUIDv7.autogenerate()

{:ok, _} =
  Ankole.Conversations.create(owner.uid, %{
    conversation_id: recovery_conversation_id,
    agent_uid: agent.uid,
    message_id: recovery_message_id,
    page_id: report.id,
    text: "A saved Conversation for local draft recovery."
  })

recovery_input = Repo.get_by!(Ankole.Signals.Signal, message_id: recovery_message_id)

{:ok, _} =
  Repo.transact(fn ->
    with :ok <-
           Ankole.Sessions.Queue.lock_session_in_tx(agent.uid, recovery_input.session_id) do
      Ankole.Sessions.Queue.mark_event_completed_in_tx(
        recovery_input,
        DateTime.utc_now(:microsecond)
      )
    end
  end)

state = %{
  base_url: origin,
  tenant_id: tenant.id,
  tenant_slug: tenant.slug,
  original_site_locale: original_site_locale,
  report_id: report.id,
  database_id: data_page.id,
  table_id: table.id,
  amount_field_id: amount.id,
  status_field_id: status.id,
  applet_id: applet.id,
  runtime_test_applet_id: runtime_test_applet.id,
  backend_report_id: backend_report.id,
  backend_database_id: backend_database.id,
  backend_applet_id: backend_applet.id,
  backend_table_id: inventory.id,
  backend_stock_field_id: stock.id,
  backend_record_id: sample.id,
  backend_publish_v2_files: backend_files["v2"],
  conversation_id: conversation_id,
  chat_controls_conversation_id: chat_controls_conversation_id,
  chat_controls_reply_id: chat_controls_reply_id,
  chat_regenerate_conversation_id: chat_regenerate_conversation_id,
  chat_regenerate_reply_id: chat_regenerate_reply_id,
  chat_failed_conversation_id: chat_failed_conversation_id,
  chat_failed_reply_id: failed_notice.id,
  history_conversation_id: history_conversation_id,
  recovery_conversation_id: recovery_conversation_id,
  message_id: chat_message.id,
  chat_text: chat_text,
  chat_attachment_name: attachment["name"],
  publish_v2_files: publish_files["v2"],
  owner: %{
    uid: owner.uid,
    cookies: cookies.(owner),
    email: owner_account.human_user.email,
    password: test_password
  },
  member: %{
    uid: member.uid,
    cookies: cookies.(member),
    email: member_account.human_user.email,
    password: test_password
  },
  viewer: %{
    uid: viewer.uid,
    cookies: cookies.(viewer),
    email: viewer_account.human_user.email,
    password: test_password
  },
  other_pod: other_pod,
  agent_uid: agent.uid
}

File.write!(state_path, Torque.encode!(state))
File.chmod!(state_path, 0o600)
IO.puts("Pod browser fixture ready at #{origin}")
Process.sleep(:infinity)
