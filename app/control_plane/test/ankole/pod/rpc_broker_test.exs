defmodule Ankole.Pod.RPCBrokerTest do
  use Ankole.DataCase, async: false

  # Driver Tasks can be cancelled while querying; each needs its own transaction.
  @moduletag sandbox: false

  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]

  alias Ankole.Pod.{Documents, Files, Pages, RPCBroker}
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.BackgroundAgentJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.RunRef
  alias Ankole.Signals.Signal
  alias Ankole.WorkerFilesFake

  setup tags do
    owner = human_fixture().principal
    attrs = %{owner_principal_uid: owner.uid}

    attrs =
      if tags[:personal_assistant], do: Map.put(attrs, :type, :personal_assistant), else: attrs

    agent = Ankole.SessionsCase.agent_fixture(attrs).principal

    base_url =
      Ankole.AIGatewayCase.start_upstream_server(fn request ->
        {:sse, 200, Ankole.AIGatewayCase.chat_completion_stream_events(request, "Fixture reply")}
      end)

    {:ok, %{"provider_id" => provider_id}} =
      Ankole.AIGateway.ModelProfiles.get_model_profile(agent.uid, "primary")

    {:ok, _} =
      Ankole.AIGateway.ProviderConfigs.update_provider(provider_id, %{base_url: "#{base_url}/v1"})

    :ok = Ankole.SessionsCase.cache_actor_runtime_models(provider_id)

    unless tags[:personal_assistant],
      do: Ankole.ConversationsFixtures.grant_chat(owner.uid, agent.uid)

    route = "pod-broker-#{System.unique_integer([:positive])}"
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    {:ok, _worker} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    room_id = Ecto.UUID.generate()

    {:ok, _} =
      create_conversation_source(owner, %{
        conversation_id: room_id,
        agent_uid: agent.uid,
        message_id: Ecto.UUID.generate(),
        room_mode: if(tags[:personal_assistant], do: :dm, else: :group),
        text: "Work with my Pod pages"
      })

    event = Repo.one!(from(s in Signal, where: s.conversation_id == ^room_id))
    assert {:ok, run} = Ankole.Sessions.Admission.admit(event, event)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: event.session_id,
      signal_id: event.id
    }

    %{
      ref: ref,
      run: run,
      owner: owner.uid,
      agent: agent.uid,
      route: route,
      ctx: %{route: route, worker_id: agent.uid, request_id: "pod-test"}
    }
  end

  test "an Agent manages native Job sources and reads their delivery history through Pod RPC",
       ctx do
    job = Ankole.WorkFixtures.applet_job(ctx.owner)

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, job.page_id, %{
               grants: [%{principal_uid: ctx.agent, role: "edit"}]
             })

    params = %{page_id: job.page_id, job_id: job.id}

    assert {:ok, %{"result" => [%{"id" => id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.list", params), ctx.ctx)

    assert id == job.id

    assert {:ok, %{"result" => action_keys}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.actions", params), ctx.ctx)

    assert job.action_key in action_keys

    assert {:ok, %{"result" => %{"id" => schedule_id}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request(
                 "jobs.schedules.put",
                 Map.merge(params, %{
                   name: "refresh",
                   payload: %{mode: "data"},
                   timezone: "Etc/UTC",
                   schedule: %{
                     kind: "every",
                     every_ms: 60_000,
                     anchor_at: DateTime.to_iso8601(DateTime.utc_now())
                   }
                 })
               ),
               ctx.ctx
             )

    assert {:ok, %{"result" => [%{"id" => ^schedule_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.schedules.list", params), ctx.ctx)

    assert {:ok, %{"result" => [_]}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("bindings.list", %{config_ref: "schedule://#{schedule_id}"}),
               ctx.ctx
             )

    {:ok, schedule} = Ankole.Schedule.get_cron_schedule(schedule_id)

    assert {:ok, %{automation_job_run: run}} =
             Ankole.Schedule.fire_cron(schedule_id, now: schedule.next_fire_at)

    assert {:ok, %{"result" => %{"id" => run_id}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("jobs.get_run", %{page_id: job.page_id, run_id: run.id}),
               ctx.ctx
             )

    assert run_id == run.id

    assert {:ok, %{"result" => [%{"id" => ^run_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.runs", params), ctx.ctx)

    assert {:ok, %{"result" => %{"deliveries" => [%{"automation_job_run_id" => ^run_id}]}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("jobs.schedules.runs", Map.put(params, :id, schedule_id)),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"webhook_endpoint" => endpoint, "token" => token}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request(
                 "jobs.webhooks.create",
                 Map.merge(params, %{
                   label: "callback",
                   expires_at: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()
                 })
               ),
               ctx.ctx
             )

    assert is_binary(token)
    refute Map.has_key?(endpoint, "token_digest")

    assert {:ok, %{"result" => %{"status" => "paused"}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("jobs.webhooks.pause", Map.put(params, :id, endpoint["id"])),
               ctx.ctx
             )

    assert {:ok, %{"result" => [%{"endpoint" => %{"status" => "paused"}}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.webhooks.list", params), ctx.ctx)
  end

  @tag personal_assistant: true
  test "a personal assistant manages its Human's sources through an admitted Pod RPC turn", ctx do
    job = Ankole.WorkFixtures.applet_job(ctx.owner, %{authorization_kind: "human"})
    params = %{page_id: job.page_id, job_id: job.id}

    assert {:ok, %{"result" => [%{"id" => id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.list", params), ctx.ctx)

    assert id == job.id

    assert {:ok, %{"result" => %{"webhook_endpoint" => endpoint, "token" => token}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request(
                 "jobs.webhooks.create",
                 Map.merge(params, %{
                   label: "Human callback",
                   expires_at: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()
                 })
               ),
               ctx.ctx
             )

    assert endpoint["authorization_kind"] == "human"
    assert endpoint["human_uid"] == ctx.owner
    assert endpoint["human_access_version"] == job.human_access_version
    assert endpoint["owner_job_id"] == job.id
    assert is_nil(endpoint["agent_uid"])

    assert {:ok, %{automation_job_run: run, signals: []}} =
             Ankole.Signals.Webhooks.receive(token, [], "personal work")

    assert run.automation_job_id == job.id

    assert {:ok, %{"result" => [%{"id" => run_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.runs", params), ctx.ctx)

    assert run_id == run.id
  end

  test "a Job can read only its admitted Skills through bundles and DAV", ctx do
    alias Ankole.AIAgent.Library.Skills
    owner = actor_fixture(ctx.owner)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: ctx.owner,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    create_skill = fn slug ->
      {:ok, skill} =
        Skills.create(owner, %{
          slug: slug,
          manifest_xml: "<page><p>Original</p></page>",
          metadata: %{"name" => slug, "description" => "Job selection"}
        })

      skill
    end

    first = create_skill.("job-original")
    {:ok, _} = Skills.set_binding(owner, first.slug, ctx.agent, true)
    source = Repo.get!(Signal, ctx.ref.signal_id)
    {_job, ref} = start_job(ctx, source)
    later = create_skill.("job-later")
    {:ok, _} = Skills.set_binding(owner, later.slug, ctx.agent, true)

    assert {:ok, %{"result" => _}} =
             RPCBroker.handle_read(ref, request("skills.bundle", %{name: first.slug}), ctx.ctx)

    assert {:error, %{"code" => "skill_not_enabled"}} =
             RPCBroker.handle_read(ref, request("skills.bundle", %{name: later.slug}), ctx.ctx)

    assert {:ok, %{"result" => _}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("skills.bundle", %{name: later.slug}),
               ctx.ctx
             )

    {:ok, grant} = Ankole.Files.Vfs.Auth.issue(ctx.agent, %{"signal_id" => ref.signal_id})

    {:ok, main_grant} =
      Ankole.Files.Vfs.Auth.issue(ctx.agent, %{"signal_id" => ctx.ref.signal_id})

    refute grant.library_scope == main_grant.library_scope

    dav = fn slug ->
      Plug.Test.conn("GET", "/api/v1/vfs/dav/Skills/#{slug}/SKILL.md")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> grant.token)
      |> AnkoleWeb.Plugs.VfsWebdav.call([])
    end

    assert dav.(first.slug).status == 200
    assert dav.(later.slug).status == 404

    {:ok, _} =
      Skills.save(owner, first.slug, %{
        manifest_xml: "<page><p>Updated</p></page>",
        metadata: first.metadata,
        base_revision: first.revision
      })

    assert dav.(first.slug).resp_body =~ "Updated"
    {:ok, _} = Skills.set_binding(owner, first.slug, ctx.agent, false)
    assert dav.(first.slug).status == 404
  end

  test "a Job that froze many Skills reads them through Drive over HTTP", ctx do
    alias Ankole.AIAgent.Library.Skills
    owner = actor_fixture(ctx.owner)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: ctx.owner,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    slugs =
      for index <- 1..40 do
        slug = String.pad_trailing("frozen-selection-#{index}-", 64, "x")

        {:ok, _} =
          Skills.create(owner, %{
            slug: slug,
            manifest_xml: "<page><p>Selected</p></page>",
            metadata: %{"name" => slug, "description" => "Job selection"}
          })

        {:ok, _} = Skills.set_binding(owner, slug, ctx.agent, true)
        slug
      end

    {_job, ref} = start_job(ctx, Repo.get!(Signal, ctx.ref.signal_id))

    # The frozen selection alone is longer than the 10,000-byte header line that
    # Bandit accepts by default.
    {:ok, selection} =
      Ankole.BackgroundAgentJobs.RuntimeProjection.for_signal(ctx.agent, ref.signal_id)

    assert byte_size(Torque.encode!(selection)) > 10_000

    {:ok, grant} = Ankole.Files.Vfs.Auth.issue(ctx.agent, %{"signal_id" => ref.signal_id})

    server =
      start_supervised!({Bandit, plug: AnkoleWeb.Plugs.VfsWebdav, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    response =
      Req.get!("http://127.0.0.1:#{port}/api/v1/vfs/dav/Skills/#{List.last(slugs)}/SKILL.md",
        headers: [authorization: "Bearer " <> grant.token],
        retry: false
      )

    assert response.status == 200
    assert response.body =~ "Selected"
  end

  test "file relays use the object-store upload ceiling and the committed object size", ctx do
    bytes = :binary.copy("a", Ankole.WorkerFiles.max_transfer_bytes() + 1)
    {:ok, maximum} = Ankole.Files.upload_limit()
    assert maximum > byte_size(bytes)
    actor = actor_fixture(ctx.agent)

    {:ok, page} =
      Pages.create(actor, %{type: "file", title: "large.bin", private_owner_uid: ctx.agent})

    {:ok, document} = Pages.create(actor, %{type: "doc", private_owner_uid: ctx.agent})

    for item <- [page, document] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, item.id, %{
          grants: [%{principal_uid: ctx.owner, role: "edit"}]
        })
    end

    worker = WorkerFilesFake.start!(ctx.route, files: %{"large.bin" => bytes})

    assert {:ok, %{"result" => %{"file" => %{"size" => size}}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("files.upload", %{
                 id: page.id,
                 role: "file",
                 base_object_id: nil,
                 home_relative_path: "large.bin"
               }),
               ctx.ctx
             )

    assert size == byte_size(bytes)

    assert {:ok, %{"result" => %{"size" => ^size}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("files.download", %{
                 id: page.id,
                 path: "large.bin",
                 home_relative_path: "received.bin"
               }),
               ctx.ctx
             )

    assert WorkerFilesFake.files(worker)["received.bin"] == bytes

    {:ok, node} = Ankole.Pod.fetch_node(page.id)
    {:ok, signal} = Ankole.Signals.get_signal(ctx.ref.signal_id)
    {:ok, message} = Ankole.Conversations.get_message(signal.message_id)

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               Ankole.Ash.update(message, :resolve_attachments, %{
                 attachments: [
                   %{"object_id" => node.object_id, "name" => "frozen.bin", "size" => 1}
                 ]
               })
             end)

    assert {:ok, _} =
             RPCBroker.handle_read(
               ctx.ref,
               request("chat.attachment.get", %{
                 conversation_id: message.conversation_id,
                 message_id: message.id,
                 position: 0,
                 home_relative_path: "frozen.bin"
               }),
               ctx.ctx
             )

    assert WorkerFilesFake.files(worker)["frozen.bin"] == bytes

    assert {:error, %{"code" => "validation_failed"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: document.id,
                 base_revision: 0,
                 markdown_home_relative_path: "large.bin"
               }),
               ctx.ctx
             )

    assert {:ok, %{revision: 0}} = Pages.fetch(document.id)
  end

  test "directory RPC lists nested children and searches their authorized breadcrumbs", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, parent} = Pages.create(actor, %{title: "Project", private_owner_uid: ctx.owner})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, parent.id, %{
        grants: [%{principal_uid: ctx.agent, role: "view"}]
      })

    {:ok, child} =
      Pages.create(actor, %{parent_id: parent.id, title: "Broker directory nested result"})

    {:ok, _hidden} =
      Pages.create(actor, %{title: "Broker directory nested secret", private_owner_uid: ctx.owner})

    assert {:ok, response} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.children", %{parent_id: parent.id}),
               ctx.ctx
             )

    assert %{"result" => %{"pages" => children}} =
             response |> Torque.encode!() |> Torque.decode!()

    assert Enum.map(children, & &1["id"]) == [child.id]
    assert hd(children)["has_children"] == false
    assert hd(children)["role"] == "view"

    assert {:ok,
            %{
              "result" => %{
                "pages" => [found],
                "ancestors" => ancestors,
                "matches" => [%{"page_id" => matched_id, "match_fields" => match_fields}]
              }
            }} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.search", %{query: "Broker directory nested"}),
               ctx.ctx
             )

    assert found["id"] == child.id
    assert matched_id == child.id
    assert match_fields == ["title"]
    assert Enum.map(ancestors, & &1["id"]) == [parent.id]
  end

  test "Agent title updates require the last-read title and preserve a concurrent Human rename",
       ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, page} = Pages.create(actor, %{title: "Original", private_owner_uid: ctx.owner})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    assert {:ok, %{"result" => %{"pages" => [%{"title" => original}]}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.search", %{query: "Original"}),
               ctx.ctx
             )

    assert {:ok, _} =
             Pages.update(actor, page.id, %{title: "Human title", expected_title: original})

    for params <- [
          %{id: page.id, title: "Agent draft"},
          %{id: page.id, title: "Agent draft", expected_title: nil},
          %{id: page.id, title: "Agent draft", expected_title: original}
        ] do
      assert {:error,
              %{"code" => "title_conflict", "details_json" => %{"title" => "Human title"}}} =
               RPCBroker.handle_write(ctx.ref, request("pages.update", params), ctx.ctx)

      assert {:ok, %{title: "Human title"}} = Pages.fetch(page.id)
    end

    assert {:ok, %{"result" => %{"pages" => [%{"title" => current}]}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.search", %{query: "Human title"}),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"title" => "Agent draft"}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.update", %{
                 id: page.id,
                 title: "Agent draft",
                 expected_title: current
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"title" => "Agent draft", "icon" => "📄"}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.update", %{id: page.id, icon: "📄"}),
               ctx.ctx
             )
  end

  for type <- [:knowledge, :file] do
    test "#{type} title and trash operations require the Human's edit grant too", ctx do
      editor = human_fixture().principal

      page = knowledge_fixture(editor.uid, "Shared knowledge", unquote(type))

      grants = [
        %{principal_uid: ctx.agent, role: "manage"},
        %{principal_uid: ctx.owner, role: "view"}
      ]

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(editor.uid, page.id, %{
          inherit_permissions: false,
          grants: [%{principal_uid: editor.uid, role: "manage"} | grants]
        })

      assert {:error, %{"code" => "forbidden"}} =
               RPCBroker.handle_write(
                 ctx.ref,
                 request("pages.update", %{
                   id: page.id,
                   title: "Unauthorized rename",
                   expected_title: page.title
                 }),
                 ctx.ctx
               )

      assert {:error, %{"code" => "forbidden"}} =
               RPCBroker.handle_write(ctx.ref, request("pages.delete", %{id: page.id}), ctx.ctx)

      assert {:ok, %{page: %{title: "Shared knowledge", deleted_at: nil}}} =
               Pages.get(actor_fixture(editor), page.id)

      grants = [
        %{principal_uid: ctx.agent, role: "manage"},
        %{principal_uid: ctx.owner, role: "edit"}
      ]

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(editor.uid, page.id, %{
          inherit_permissions: false,
          grants: [%{principal_uid: editor.uid, role: "manage"} | grants]
        })

      assert {:ok, %{"result" => %{"title" => "Approved rename"}}} =
               RPCBroker.handle_write(
                 ctx.ref,
                 request("pages.update", %{
                   id: page.id,
                   title: "Approved rename",
                   expected_title: page.title
                 }),
                 ctx.ctx
               )
    end
  end

  for type <- [:knowledge, :file] do
    test "#{type} restore checks the requester's current trash visibility and edit grant", ctx do
      editor = human_fixture().principal

      for role <- [nil, "view", "edit"] do
        page = knowledge_fixture(editor.uid, "Archived rule", unquote(type))

        grants =
          [%{principal_uid: ctx.agent, role: "manage"}] ++
            if(role, do: [%{principal_uid: ctx.owner, role: role}], else: [])

        {:ok, _} =
          Ankole.Pod.PagesFixtures.set_sharing(editor.uid, page.id, %{
            inherit_permissions: false,
            grants: [%{principal_uid: editor.uid, role: "manage"} | grants]
          })

        {:ok, _} = Pages.delete(actor_fixture(editor), page.id)

        result =
          RPCBroker.handle_write(ctx.ref, request("pages.restore", %{id: page.id}), ctx.ctx)

        case role do
          nil -> assert {:error, %{"code" => "not_found"}} = result
          "view" -> assert {:error, %{"code" => "forbidden"}} = result
          "edit" -> assert {:ok, %{"result" => %{"deleted_at" => nil}}} = result
        end

        assert {:ok, current} = Pages.fetch(page.id)
        assert is_nil(current.deleted_at) == (role == "edit")
      end
    end
  end

  test "Brain file uploads require the requester's edit permission", ctx do
    editor = human_fixture().principal
    WorkerFilesFake.start!(ctx.route, files: %{"brain.txt" => "Shared bytes"})

    for role <- [nil, "view", "edit"] do
      page = knowledge_fixture(editor.uid, "Upload target", :file)
      {:ok, _} = Ankole.Pod.Files.Content.write(actor_fixture(editor), page.id, "original")
      {:ok, page} = Pages.fetch(page.id)

      grants =
        [
          %{principal_uid: editor.uid, role: "manage"},
          %{principal_uid: ctx.agent, role: "manage"}
        ] ++
          if(role, do: [%{principal_uid: ctx.owner, role: role}], else: [])

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(editor.uid, page.id, %{
          inherit_permissions: false,
          grants: grants
        })

      result =
        RPCBroker.handle_write(
          ctx.ref,
          request("files.upload", %{
            id: page.id,
            role: "file",
            base_object_id: page.object_id,
            home_relative_path: "brain.txt"
          }),
          ctx.ctx
        )

      case role do
        nil -> assert {:error, %{"code" => "not_found"}} = result
        "view" -> assert {:error, %{"code" => "forbidden"}} = result
        "edit" -> assert {:ok, %{"result" => %{"file" => %{"size" => 12}}}} = result
      end
    end
  end

  for operation <- ["pages.set_sharing", "pages.update_sharing"], type <- [:knowledge] do
    test "#{operation} on #{type} cannot grant a knowledge requester edit access using only Agent manage",
         ctx do
      editor = human_fixture().principal

      page = knowledge_fixture(editor.uid, "Shared rule")

      knowledge = page

      replacement = [
        %{principal_uid: ctx.agent, role: "manage"},
        %{principal_uid: ctx.owner, role: "edit"}
      ]

      for role <- ["view", "edit", "manage"] do
        {:ok, _} =
          Ankole.Pod.PagesFixtures.set_sharing(editor.uid, page.id, %{
            inherit_permissions: false,
            grants: [
              %{principal_uid: editor.uid, role: "manage"},
              %{principal_uid: ctx.agent, role: "manage"},
              %{principal_uid: ctx.owner, role: role}
            ]
          })

        {:ok, sharing} = Pages.sharing(actor_fixture(editor), page.id)

        params =
          if unquote(operation) == "pages.set_sharing",
            do: %{id: page.id, sharing_version: sharing.sharing_version, grants: replacement},
            else: %{id: page.id, upserts: replacement}

        result = RPCBroker.handle_write(ctx.ref, request(unquote(operation), params), ctx.ctx)

        if role == "manage" do
          assert {:ok, _} = result
          assert {:ok, _} = Pages.authorize(actor_fixture(ctx.owner), knowledge.id, "node_edit")

          assert {:error, :forbidden} =
                   Pages.authorize(actor_fixture(ctx.owner), page.id, "node_manage")
        else
          assert {:error, %{"code" => "forbidden"}} = result

          if role == "view" do
            assert {:error, :forbidden} =
                     Pages.authorize(actor_fixture(ctx.owner), knowledge.id, "node_edit")
          end
        end
      end
    end
  end

  for type <- [:knowledge, :file] do
    test "moving #{type} into a Brain entry requires requester edit access to the destination",
         ctx do
      editor = human_fixture().principal

      destination = knowledge_fixture(editor.uid, "Shared Brain entry")
      draft = knowledge_fixture(ctx.owner, "Proposed entry", unquote(type))

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, draft.id, %{
          inherit_permissions: false,
          grants: [
            %{principal_uid: ctx.owner, role: "manage"},
            %{principal_uid: ctx.agent, role: "manage"}
          ]
        })

      for role <- ["view", "edit"] do
        {:ok, _} =
          Ankole.Pod.PagesFixtures.set_sharing(editor.uid, destination.id, %{
            inherit_permissions: false,
            grants: [
              %{principal_uid: editor.uid, role: "manage"},
              %{principal_uid: ctx.agent, role: "manage"},
              %{principal_uid: ctx.owner, role: role}
            ]
          })

        result =
          RPCBroker.handle_write(
            ctx.ref,
            request("pages.move", %{id: draft.id, parent_id: destination.id}),
            ctx.ctx
          )

        if role == "view" do
          assert {:error, %{"code" => "forbidden"}} = result
          assert {:ok, %{parent_id: parent_id}} = Pages.fetch(draft.id)
          assert parent_id == draft.parent_id
        else
          assert {:ok, %{"result" => %{"parent_id" => parent_id}}} = result
          assert parent_id == destination.id
        end
      end
    end
  end

  for operation <- ["pages.write", "files.upload"] do
    test "#{operation} reports the final relay error without changing the page", ctx do
      operation = unquote(operation)
      type = if operation == "files.upload", do: "file", else: "doc"

      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
          type: type,
          title: "Unchanged"
        })

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
          grants: [%{principal_uid: ctx.agent, role: "edit"}]
        })

      expected_object =
        if operation == "files.upload" do
          {:ok, uploaded} =
            Files.upload(actor_fixture(ctx.owner), page.id, "file", nil, "Unchanged", "original")

          uploaded.file.object_id
        else
          nil
        end

      WorkerFilesFake.start!(ctx.route,
        files: %{"source.xml" => "<page><p>New content</p></page>"},
        push_result: {"read_failed", "Worker could not complete the source read"}
      )

      params = %{
        id: page.id,
        base_revision: 0,
        base_object_id: expected_object,
        markdown_home_relative_path: "source.xml",
        home_relative_path: "source.xml"
      }

      assert {:error, %{"code" => "validation_failed"}} =
               RPCBroker.handle_write(ctx.ref, request(operation, params), ctx.ctx)

      assert {:ok, detail} =
               Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

      assert detail.page.revision == 0
      assert detail.page.object_id == expected_object
    end
  end

  test "incremental sharing RPC adds a colleague without replacing another collaborator", ctx do
    actor = actor_fixture(ctx.agent)
    {:ok, page} = Pages.create(actor, %{title: "Contract", private_owner_uid: ctx.agent})
    other = human_fixture().principal
    colleague = Ankole.SessionsCase.agent_fixture().principal

    {:ok, _} =
      Pages.update_sharing(actor, page.id, %{
        upserts: [%{principal_uid: other.uid, role: "view", target_scope: "self"}]
      })

    assert {:ok, _} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.update_sharing", %{
                 id: page.id,
                 upserts: [%{principal_uid: colleague.uid, role: "edit", target_scope: "self"}]
               }),
               ctx.ctx
             )

    assert {:ok, _} = Pages.authorize(actor_fixture(other), page.id, "node_view")
    assert {:ok, _} = Pages.authorize(actor_fixture(colleague), page.id, "node_edit")
  end

  test "sharing RPC uses the page manage contract and its current version", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner)
    {:ok, page} = Pages.create(actor, %{private_owner_uid: ctx.owner})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    {:ok, sharing} = Pages.sharing(actor, page.id)
    params = %{id: page.id, sharing_version: sharing.sharing_version, grants: []}

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_write(ctx.ref, request("pages.set_sharing", params), ctx.ctx)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "manage"}]
      })

    assert {:ok, %{"result" => readable}} =
             RPCBroker.handle_read(ctx.ref, request("pages.sharing", %{id: page.id}), ctx.ctx)

    assert [%{"principal_uid" => agent_uid, "rule_kind" => "role"}] = readable["grants"]
    assert agent_uid == ctx.agent

    params = %{
      id: page.id,
      sharing_version: readable["sharing_version"],
      grants: [%{principal_uid: ctx.agent, role: "manage"}]
    }

    assert {:ok, %{"result" => %{"id" => id}}} =
             RPCBroker.handle_write(ctx.ref, request("pages.set_sharing", params), ctx.ctx)

    assert id == page.id

    assert {:error, %{"code" => "sharing_conflict"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.set_sharing", %{params | sharing_version: "stale"}),
               ctx.ctx
             )

    guest = human_fixture(%{membership: :guest}).principal

    assert {:ok, %{"result" => latest}} =
             RPCBroker.handle_read(ctx.ref, request("pages.sharing", %{id: page.id}), ctx.ctx)

    guest_params = %{
      id: page.id,
      sharing_version: latest["sharing_version"],
      grants: [
        %{principal_uid: ctx.agent, role: "manage"},
        %{principal_uid: guest.uid, role: "view"}
      ]
    }

    assert {:error, %{"code" => "guest_forbidden_in_private"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.set_sharing", guest_params),
               ctx.ctx
             )
  end

  test "Human-driven sharing uses the executing Agent grants independently of Human grants",
       ctx do
    {source, _parent} = page_request(ctx)
    assert {:ok, _run} = Ankole.Sessions.Admission.admit(source, source)
    ref = %RunRef{agent_uid: ctx.agent, session_id: source.session_id, signal_id: source.id}
    colleague = human_fixture().principal
    colleague_actor = Ankole.PrincipalsFixtures.actor_fixture(colleague.uid)
    {:ok, page} = Pages.create(colleague_actor, %{private_owner_uid: colleague.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(colleague.uid, page.id, %{
        grants: [
          %{principal_uid: ctx.agent, role: "manage"},
          %{principal_uid: ctx.owner, role: "view"}
        ]
      })

    {:ok, sharing} = Pages.sharing(colleague_actor, page.id)

    params = %{
      id: page.id,
      sharing_version: sharing.sharing_version,
      grants: [%{principal_uid: ctx.agent, role: "manage"}]
    }

    assert {:ok, _} = RPCBroker.handle_write(ref, request("pages.set_sharing", params), ctx.ctx)

    # The initiating Human's access is not intersected with the Agent's grants.
    # Removing Agent manage still rejects the same operation.
    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(colleague.uid, page.id, %{
        grants: [
          %{principal_uid: ctx.agent, role: "edit"},
          %{principal_uid: ctx.owner, role: "manage"}
        ]
      })

    {:ok, sharing} = Pages.sharing(colleague_actor, page.id)
    params = %{params | sharing_version: sharing.sharing_version}

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_write(ref, request("pages.set_sharing", params), ctx.ctx)
  end

  test "document RPC transfers Markdown over the signed relay and keeps CAS at its owner",
       ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{title: "Agent report"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    markdown = "Agent report"
    fake = WorkerFilesFake.start!(ctx.route, files: %{"report.md" => markdown})

    assert {:ok, %{"result" => %{"page" => %{"revision" => 1}} = written}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 0,
                 markdown_home_relative_path: "report.md"
               }),
               ctx.ctx
             )

    refute Map.has_key?(written, "content")
    assert {:ok, detail} = Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
    assert detail.content.plain_text == "Agent report"

    assert {:error, %{"code" => "revision_conflict", "details_json" => %{"revision" => 1}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 0,
                 markdown_home_relative_path: "report.md"
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"content" => %{"markdown_file" => true}}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.read", %{
                 id: page.id,
                 markdown_home_relative_path: "received.md"
               }),
               ctx.ctx
             )

    assert {:ok, exported} = Ankole.Kernel.vfs_document_export(detail.content.content)
    assert WorkerFilesFake.files(fake)["received.md"] == exported
    assert exported =~ "ankole:block"
    assert exported =~ markdown

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               1,
               "<page><p>Human edit</p></page>"
             )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        inherit_permissions: false,
        grants: []
      })

    before = WorkerFilesFake.pushes(fake)

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 2,
                 markdown_home_relative_path: "report.md"
               }),
               ctx.ctx
             )

    assert WorkerFilesFake.pushes(fake) == before

    assert {:ok, %{content: %{plain_text: "Human edit"}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
  end

  test "creating a collaboration document through the CLI RPC persists its Markdown body", ctx do
    owner = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner)
    {:ok, parent} = Pages.create(owner, %{title: "Proposals"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, parent.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    assert {:ok, %{"result" => %{"id" => id}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.create", %{
                 type: "doc",
                 parent_id: parent.id,
                 title: "Pilot",
                 markdown: "# Proposal\n\nBudget: **187 CNY**.\n\nReference: PILOT-42."
               }),
               ctx.ctx
             )

    assert {:ok, %{page: %{type: :doc, parent_id: parent_id}, content: content}} =
             Pages.get(owner, id)

    assert parent_id == parent.id
    assert content.plain_text =~ "187 CNY"
    assert content.plain_text =~ "PILOT-42"
    assert content.content =~ "<strong>187 CNY</strong>"
  end

  test "knowledge RPC accepts the CLI's streamed Markdown body", ctx do
    page = knowledge_fixture(ctx.owner, "Shared instructions")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    WorkerFilesFake.start!(ctx.route, files: %{"knowledge.md" => "Updated instructions"})

    assert {:ok, _} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: page.revision,
                 markdown_home_relative_path: "knowledge.md"
               }),
               ctx.ctx
             )

    assert {:ok, %{content: %{plain_text: "Updated instructions"}}} =
             Pages.get(actor_fixture(ctx.owner), page.id)
  end

  test "a colleague can immediately list and read its new private business document", ctx do
    fake = WorkerFilesFake.start!(ctx.route)

    assert {:ok, %{"result" => %{"id" => id}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.create", %{
                 type: "doc",
                 private_owner_uid: ctx.agent,
                 title: "Private legal rule",
                 markdown: "Internal rule"
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => pages}} =
             RPCBroker.handle_read(ctx.ref, request("pages.list", %{scope: "private"}), ctx.ctx)

    assert Enum.any?(pages, &(&1["id"] == id))

    assert {:ok, %{"result" => %{"page" => %{"id" => ^id}}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("pages.read", %{id: id, markdown_home_relative_path: "rule.md"}),
               ctx.ctx
             )

    assert WorkerFilesFake.files(fake)["rule.md"] =~ "Internal rule"
    assert {:error, _} = Pages.get(actor_fixture(ctx.owner), id)

    assert {:ok, _} =
             RPCBroker.handle_write(ctx.ref, request("pages.delete", %{id: id}), ctx.ctx)

    assert {:ok, %{"result" => trashed}} =
             RPCBroker.handle_read(ctx.ref, request("pages.list", %{scope: "trash"}), ctx.ctx)

    assert Enum.any?(trashed, &(&1["id"] == id))

    assert {:ok, _} =
             RPCBroker.handle_write(ctx.ref, request("pages.restore", %{id: id}), ctx.ctx)

    assert {:ok, _} = Pages.get(actor_fixture(ctx.agent), id)
    assert {:error, _} = Pages.get(actor_fixture(ctx.owner), id)
  end

  test "Pod drive relay requires current access to the page", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "file",
        title: "Report"
      })

    {:ok, _} =
      Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        page.id,
        "file",
        nil,
        "report.txt",
        "saved bytes"
      )

    fake = WorkerFilesFake.start!(ctx.route)

    request =
      request("files.download", %{
        id: page.id,
        path: "report.txt",
        home_relative_path: "received/report.txt"
      })

    assert {:error, %{"code" => "not_found"}} =
             RPCBroker.handle_read(ctx.ref, request, ctx.ctx)

    assert WorkerFilesFake.files(fake) == %{}

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "view"}]
      })

    assert {:ok, %{"result" => %{"object_id" => _}}} =
             RPCBroker.handle_read(ctx.ref, request, ctx.ctx)

    assert WorkerFilesFake.files(fake) == %{"received/report.txt" => "saved bytes"}
  end

  test "pages created after completion and multiple Job continuations keep their Human source",
       ctx do
    {source, parent} = page_request(ctx)
    {job, ref} = start_job(ctx, source)
    assert created_page(ctx, ref, parent, "Report")["saved_from_message_id"] == source.message_id

    wake = complete_job(job)
    assert wake.producer == :kernel
    assert wake.type == "background_agent_job.completed"
    assert wake.message_id == nil
    assert wake.data["job_id"] == job.id

    main_ref = %RunRef{agent_uid: ctx.agent, session_id: wake.session_id, signal_id: wake.id}

    assert created_page(ctx, main_ref, parent, "Main result")["saved_from_message_id"] ==
             source.message_id

    {continued, ref} = start_job(ctx, wake, job)

    assert created_page(ctx, ref, parent, "Applet", "applet")["saved_from_message_id"] ==
             source.message_id

    {_, ref} = start_job(ctx, complete_job(continued), continued)

    assert created_page(ctx, ref, parent, "Second continuation")["saved_from_message_id"] ==
             source.message_id
  end

  test "a new Human follow-up owns the continued Job's new pages", ctx do
    {original, parent} = page_request(ctx)
    {job, _ref} = start_job(ctx, original)
    _wake = complete_job(job)
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.post(ctx.owner, original.conversation_id, %{
               message_id: message_id,
               text: "Create another result from this new request."
             })

    source = Repo.get_by!(Signal, message_id: message_id)
    {continued, ref} = start_job(ctx, source, job)
    assert created_page(ctx, ref, parent, "Follow-up")["saved_from_message_id"] == message_id
    assert original_request(ref)["text"] == "Create another result from this new request."

    {_, ref} = start_job(ctx, complete_job(continued), continued)

    assert created_page(ctx, ref, parent, "Follow-up continuation")["saved_from_message_id"] ==
             message_id
  end

  test "a continuation without a message source terminates on a cyclic Job chain", ctx do
    {source, parent} = page_request(ctx)
    service = Ankole.WorkFixtures.service_source(ctx.agent)
    reply_route = %{"conversation_id" => source.conversation_id}
    {first, _ref} = start_job(ctx, service, nil, reply_route)
    assert {:ok, _} = BackgroundAgentJobs.request_stop(first.id, %{"agent_uid" => ctx.agent})
    {second, ref} = start_job(ctx, service, nil, reply_route)

    # Public respawn cannot create a cycle. Exercise the persisted traversal guard.
    first |> Ecto.Changeset.change(continued_from_job_id: second.id) |> Repo.update!()
    second |> Ecto.Changeset.change(continued_from_job_id: first.id) |> Repo.update!()

    assert created_page(ctx, ref, parent, "No inferred source")["saved_from_message_id"] == nil
  end

  test "Job execution carries the original Human text independently of the delegated task", ctx do
    text =
      "Prepare the report.\nDo not add the sample now; I will add it myself. Keep \"quoted\" text."

    {source, parent} = page_request(ctx, text)
    {job, ref} = start_job(ctx, source)
    assert job.task == "Save the deliverable as a Page."

    assert Ankole.Conversations.Route.human_request(ref) == %{
             "message_id" => source.message_id,
             "text" => text
           }

    # A later UI edit cannot replace this already-consumed Signal version.
    Repo.get_by!(Ankole.Conversations.Message, id: source.message_id)
    |> Ecto.Changeset.change(text: "Use a relaxed implementation plan.")
    |> Repo.update!()

    assert original_request(ref)["text"] == text

    assert created_page(ctx, ref, parent, "Original request")["saved_from_message_id"] ==
             source.message_id

    wake = complete_job(job)

    main = %{
      agent_uid: ctx.agent,
      signal_id: wake.id,
      context: %{conversation: %{timezone: "UTC"}}
    }

    messages = Ankole.Sessions.Prompt.user(main, wake)
    parts = Enum.flat_map(messages, & &1["content"])

    block =
      Enum.find_value(parts, fn part ->
        value = part["text"]
        if is_binary(value) and String.contains?(value, "<original_human_request>"), do: value
      end)

    assert decode_original_request(block) == %{"message_id" => source.message_id, "text" => text}

    {_, continued_ref} = start_job(ctx, wake, job)
    assert original_request(continued_ref)["text"] == text
  end

  test "only an applied new Human steer changes execution context, not creation provenance",
       ctx do
    {source, parent} = page_request(ctx, "Request A: build the report; I will add the sample.")
    {job, ref} = start_job(ctx, source)
    text = "Request B: change the report language. Do not perform my reserved step."
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.post(ctx.owner, source.conversation_id, %{
               message_id: message_id,
               text: text
             })

    follow_up = Repo.get_by!(Signal, message_id: message_id)

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => follow_up.id,
               "message" => "Delegated summary with less detail."
             })

    assert steer.data["source_signal_id"] == follow_up.id
    assert original_request(ref)["text"] =~ "Request A:"

    # The live mailbox delivers B with its summary, without changing context
    # before the Worker acknowledges that it actually applied the message.
    envelope = Ankole.Sessions.TurnEnvelope.mailbox_updated(ref, steer)
    assert {:mailbox_updated, update} = envelope.body

    assert decode_original_request(
             Torque.decode!(update.signal.payload_json)["original_human_request"]
           )["text"] == text

    assert original_request(ref)["text"] =~ "Request A:"

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{
                 "status" => "running",
                 "runtime_thread_id" => "human-request-#{job.id}",
                 "metadata" => %{"applied_source_signal_id" => follow_up.id}
               },
               turn_ref: ref,
               worker_id: ctx.agent
             )

    refute Map.has_key?(running.metadata, "applied_source_signal_id")

    # A successful Codex steer is already a persisted client receipt before
    # terminal status. Recovery must start with B, not start with A and wait
    # for a later polling cycle to resend B.
    record_request_turn(running, ref, ctx.agent, steer.id, "in_progress")
    checkpointed = BackgroundAgentJobs.get_job_for_agent(job.id, ctx.agent)
    assert checkpointed.status == :running
    assert checkpointed.metadata["applied_source_signal_id"] == steer.id
    assert Repo.reload!(steer).completed_at == nil
    assert original_request(ref)["text"] == text
    assert original_request(ref, "adopt")["text"] == text

    assert created_page(ctx, ref, parent, "After applied B")["saved_from_message_id"] ==
             source.message_id

    assert {:ok, %{command_event: summary}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => source.id,
               "message" => "Check the result again."
             })

    assert {:mailbox_updated, summary_update} =
             Ankole.Sessions.TurnEnvelope.mailbox_updated(ref, summary).body

    assert decode_original_request(
             Torque.decode!(summary_update.signal.payload_json)["original_human_request"]
           )["text"] == text

    record_request_turn(running, ref, ctx.agent, steer.id, "completed")

    assert {:ok, %{job: completed, wakeup_event: wake}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{
                 "status" => "succeeded",
                 "metadata" => %{"applied_source_signal_id" => source.id},
                 "result" => %{"output_text" => "Report ready."}
               },
               turn_ref: ref,
               worker_id: ctx.agent,
               applied_signal_ids: [summary.id, steer.id]
             )

    assert completed.source_signal_id == source.id
    assert completed.metadata["applied_source_signal_id"] == steer.id
    assert Repo.reload!(steer).completed_at != nil
    assert original_request(ref)["text"] == text
    assert Ankole.Conversations.Route.source_message_id(ref) == source.message_id

    # Worker-supplied metadata cannot clear the CP's applied reference.
    assert {:ok, %{job: unchanged}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent, %{
               "status" => "succeeded",
               "metadata" => %{"applied_source_signal_id" => nil}
             })

    assert unchanged.metadata["applied_source_signal_id"] == steer.id

    {_, continued_ref} = start_job(ctx, wake, completed)
    assert original_request(continued_ref)["text"] == text

    assert created_page(ctx, continued_ref, parent, "Continued after B")["saved_from_message_id"] ==
             source.message_id
  end

  test "a provider readmission in an older source Chat cannot reset applied cross-Chat intent",
       ctx do
    {source, _parent} = page_request(ctx, "Old Chat request A")
    {job, ref} = start_job(ctx, source)
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             create_conversation_source(ctx.owner, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: message_id,
               agent_uid: ctx.agent,
               text: "New Chat request B"
             })

    follow_up = Repo.get_by!(Signal, message_id: message_id)

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => follow_up.id,
               "message" => "Use this new request."
             })

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{"status" => "running", "runtime_thread_id" => "cross-chat-#{job.id}"},
               turn_ref: ref,
               worker_id: ctx.agent
             )

    record_request_turn(running, ref, ctx.agent, steer.id, "in_progress")

    source
    |> Ecto.Changeset.change(
      last_attempt_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
    )
    |> Repo.update!()

    assert original_request(ref)["text"] == "New Chat request B"
  end

  test "a Job without a native Human source does not invent original instructions", ctx do
    {source, _parent} = page_request(ctx)
    service = Ankole.WorkFixtures.service_source(ctx.agent)
    {_job, ref} = start_job(ctx, service, nil, %{"conversation_id" => source.conversation_id})
    assert Ankole.Conversations.Route.human_request(ref) == nil
    assert original_request(ref) == nil
  end

  defp original_request(ref, mode \\ "start") do
    signal = Repo.get!(Signal, ref.signal_id)

    envelope =
      Ankole.Sessions.TurnEnvelope.turn_start(ref, signal, %{request_context: %{}}, mode, nil)

    bytes = Ankole.RuntimeFabric.encode_envelope(envelope)

    assert {:ok, %{body: {:turn_start, start}}} =
             Ankole.RuntimeFabric.V1.Envelope.decode(bytes)

    context = Torque.decode!(start.request_context_json)

    case context["original_human_request"] do
      "" -> nil
      block -> decode_original_request(block)
    end
  end

  defp decode_original_request(block) do
    [_, json] = String.split(block, "<original_human_request>\n", parts: 2)
    json |> String.trim_trailing("\n</original_human_request>") |> Torque.decode!()
  end

  defp record_request_turn(job, ref, worker, receipt_id, status) do
    now = DateTime.utc_now(:microsecond)

    user = %{
      "position" => 0,
      "item_key" => "client:#{receipt_id}",
      "item" => %{
        "type" => "userMessage",
        "id" => receipt_id,
        "clientId" => receipt_id,
        "content" => [%{"type" => "text", "text" => "Applied Human B and delegated message."}]
      }
    }

    final = %{
      "position" => 1,
      "item_key" => "final",
      "item" => %{
        "type" => "agentMessage",
        "id" => "final",
        "text" => "Report ready."
      }
    }

    assert {:ok, _} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               job.agent_uid,
               %{
                 "attempt" => job.attempts,
                 "runtime_thread_id" => job.runtime_thread_id,
                 "runtime_turn_id" => "human-request-turn-#{job.id}",
                 "kind" => "agent",
                 "status" => status,
                 "revision" => if(status == "completed", do: 1, else: 0),
                 "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
                 "turn_items" => if(status == "completed", do: [user, final], else: [user]),
                 "progress" => %{
                   "completed_items" => if(status == "completed", do: 2, else: 1),
                   "tool_calls" => 0,
                   "tools_used" => [],
                   "files_changed" => []
                 },
                 "error" => %{},
                 "started_at" => job.started_at,
                 "completed_at" => if(status == "completed", do: now)
               },
               ref,
               worker
             )
  end

  defp create_conversation_source(human, attrs) do
    Repo.transact_top_level(fn ->
      with {:ok, detail} <- Ankole.ConversationsFixtures.create(human, attrs) do
        signal = Repo.get_by!(Signal, message_id: attrs.message_id)
        key = %{agent_uid: signal.agent_uid, session_id: signal.session_id}

        if Ankole.Sessions.driver_pid(key) == :undefined,
          do: Ankole.SessionsCase.stub_driver(key)

        {:ok, detail}
      end
    end)
  end

  defp page_request(ctx, text \\ "Create a report and an applet.") do
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             create_conversation_source(ctx.owner, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: message_id,
               agent_uid: ctx.agent,
               text: text
             })

    {:ok, parent} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        title: "Agent deliverables"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, parent.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    {Repo.get_by!(Signal, message_id: message_id), parent.id}
  end

  defp start_job(ctx, source, previous \\ nil, reply_route \\ nil) do
    attrs = %{
      "agent_uid" => ctx.agent,
      "owner_session_id" => source.session_id,
      "source_signal_id" => source.id,
      "source_tool_call_id" => Ecto.UUID.generate(),
      "reply_route" => reply_route || Ankole.Conversations.Route.snapshot(%{signal_id: source.id})
    }

    result =
      Repo.transact_top_level(
        fn ->
          result =
            if previous do
              Ankole.BackgroundAgentJobs.Dispatch.respawn_with_dispatch_in_tx(
                previous.id,
                Map.put(attrs, "message", "Continue the task.")
              )
            else
              Ankole.BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(
                Map.merge(attrs, %{
                  "title" => "Create deliverable",
                  "task" => "Save the deliverable as a Page."
                })
              )
            end

          with {:ok, %{job: job} = created} <- result do
            # This broker test drives Admission itself; reserve the Driver before dispatch commits.
            Ankole.SessionsCase.stub_driver(%{
              agent_uid: ctx.agent,
              session_id: BackgroundAgentJobs.job_session_id(job.id)
            })

            {:ok, created}
          end
        end,
        after_commit: fn created -> Ankole.Signals.publish_committed(created.dispatch_event) end
      )

    assert {:ok, %{job: job, dispatch_event: dispatch}} = result

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{} = attempt} =
             Ankole.Sessions.Admission.admit(dispatch, dispatch)

    assert {:ok, :sent_or_queued} = Ankole.Sessions.CodexJob.start(attempt)
    expected = Ankole.Sessions.JobTurnRef.to_proto(attempt.job_ref)

    assert_receive {:actor_lane,
                    %FabricProto.Envelope{
                      body: {:turn_start, %FabricProto.TurnStart{turn: ^expected}}
                    }},
                   1_000

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{
                 "status" => "running",
                 "runtime_thread_id" => job.runtime_thread_id || "source-test-#{job.id}"
               },
               turn_ref: attempt.job_ref,
               worker_id: ctx.agent
             )

    {job, attempt.job_ref}
  end

  defp complete_job(job) do
    assert {:ok, %{wakeup_event: wake}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               job.agent_uid,
               %{"status" => "succeeded"},
               transition_action: :external_complete
             )

    wake
  end

  defp created_page(ctx, ref, parent, title, type \\ "doc") do
    assert {:ok, %{"result" => page}} =
             RPCBroker.handle_write(
               ref,
               request("pages.create", %{parent_id: parent, title: title, type: type}),
               ctx.ctx
             )

    page
  end

  test "Applet RPC retains Agent identity, logs and the current RunRef on each capability write",
       ctx do
    {:ok, base} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{type: "base"})

    {:ok, table} =
      Ankole.Pod.Bases.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        base.id,
        %{name: "Orders"}
      )

    {:ok, field} =
      Ankole.Pod.Bases.create_field(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "text", name: "Label"}
      )

    {:ok, applet} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{type: "applet"})

    for page <- [base, applet] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
          grants: [%{principal_uid: ctx.agent, role: "edit"}]
        })
    end

    source = """
    export default {
      'POST /write':async r=>{console.log('writing-as',r.principal.uid); const result=await AnkoleRuntime.base.write('#{table.id}',r.body);return {principal:r.principal,result}},
      'GET /crash':()=>{console.warn('debug-log');throw new Error('agent-debug')}
    }
    """

    manifest =
      Enum.map(
        [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
        fn {path, bytes} ->
          {:ok, blob} = Ankole.Files.store(bytes)

          {:ok, _} =
            Ankole.Files.commit(ctx.agent, [
              Map.merge(blob, %{path: "publish/#{applet.id}/#{path}", source: "agent"})
            ])

          %{path: path, object_id: blob.object_id, source_path: "publish/#{applet.id}/#{path}"}
        end
      )

    {:ok, _} =
      Files.publish(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.agent),
        applet.id,
        0,
        manifest,
        {ctx.ref, ctx.agent}
      )

    attrs = %{
      id: applet.id,
      method: "POST",
      path: "/write",
      body: %{creates: [%{data: %{field.id => "Committed"}}]}
    }

    assert {:ok,
            %{
              "result" => %{
                "status" => 200,
                "body" => %{"principal" => principal},
                "logs" => logs
              }
            }} = RPCBroker.handle_write(ctx.ref, request("applets.call", attrs), ctx.ctx)

    assert principal["uid"] == ctx.agent
    assert principal["kind"] == "agent"
    assert Enum.any?(logs, &String.contains?(&1["message"], ctx.agent))
    assert {:ok, _} = Ankole.Sessions.Run.finalize(ctx.run, :silent)

    assert {:ok,
            %{"result" => %{"status" => 422, "body" => %{"error" => %{"code" => "run_closed"}}}}} =
             RPCBroker.handle_write(ctx.ref, request("applets.call", attrs), ctx.ctx)

    assert {:ok, %{records: [record]}} =
             Ankole.Pod.Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               table.id,
               %{}
             )

    assert record["data"][field.id] == "Committed"

    assert {:ok,
            %{"result" => %{"status" => 500, "debug" => %{"message" => debug}, "logs" => [_]}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("applets.call", %{id: applet.id, method: "GET", path: "/crash"}),
               ctx.ctx
             )

    assert debug =~ "agent-debug"
  end

  test "Applet Job and Binding reads use the executing colleague permissions without a Base id",
       ctx do
    actor = actor_fixture(ctx.agent)
    {:ok, applet} = Pages.create(actor, %{type: "applet", private_owner_uid: ctx.agent})

    publish_applet_fixture(
      %{actor: actor, page: applet},
      "export default {actions:{work:{idempotent:true,handler:()=>({ok:true})}}}"
    )

    {:ok, job} =
      Ankole.AutomationJobs.create_applet_job(actor, applet.id, "work", %{
        authorization_kind: "service"
      })

    binding_params = %{config_ref: "applet://#{applet.id}", automation_job_id: job.id}

    assert {:ok, %{"result" => %{"id" => binding_id}}} =
             RPCBroker.handle_write(ctx.ref, request("bindings.put", binding_params), ctx.ctx)

    assert {:ok, ^binding_id} = Ecto.UUID.cast(binding_id)

    assert {:ok, %{"result" => %{"id" => ^binding_id, "enabled" => true}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("bindings.put", Map.put(binding_params, :id, binding_id)),
               ctx.ctx
             )

    {:ok, %{receipts: [receipt]}} =
      Ankole.Signals.emit(binding_params.config_ref, %{
        id: "broker-action",
        type: "test.trigger",
        data: %{}
      })

    run_id = receipt.automation_job_run_id
    {:ok, base} = Pages.create(actor, %{type: "base", private_owner_uid: ctx.agent})
    {:ok, table} = Ankole.Pod.Bases.create_table(actor, base.id, %{name: "Source"})

    reads = [
      {"jobs.actions", %{page_id: applet.id}},
      {"jobs.runs", %{page_id: applet.id, job_id: job.id}},
      {"jobs.list", %{page_id: applet.id}},
      {"jobs.get_run", %{page_id: applet.id, run_id: run_id}},
      {"bindings.list", %{config_ref: binding_params.config_ref}},
      {"bindings.list", %{config_ref: "job://#{job.id}"}},
      {"bindings.list", %{config_ref: "base://#{table.id}"}}
    ]

    # The colleague can use its private business resources without sharing them with the requester.
    assert {:ok, [_]} = Ankole.AutomationJobs.list_applet_jobs(actor, applet.id)
    assert {:ok, [_]} = Ankole.Signals.list_event_bindings(actor, binding_params.config_ref)

    for {operation, params} <- reads do
      assert {:ok, %{"result" => _}} =
               RPCBroker.handle_read(ctx.ref, request(operation, params), ctx.ctx)
    end

    for page <- [applet, base] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, page.id, %{
          grants: [%{principal_uid: ctx.owner, role: "view"}]
        })
    end

    assert {:ok, %{"result" => [%{"id" => job_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("jobs.list", %{page_id: applet.id}), ctx.ctx)

    assert job_id == job.id

    assert {:ok, %{"result" => %{"id" => ^run_id, "automation_job_id" => ^job_id}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("jobs.get_run", %{page_id: applet.id, run_id: run_id}),
               ctx.ctx
             )

    assert {:ok, %{"result" => [%{"id" => ^binding_id}]}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("bindings.list", %{config_ref: binding_params.config_ref}),
               ctx.ctx
             )

    for reference <- ["job://#{job.id}", "base://#{table.id}"] do
      assert {:ok, %{"result" => []}} =
               RPCBroker.handle_read(
                 ctx.ref,
                 request("bindings.list", %{config_ref: reference}),
                 ctx.ctx
               )
    end

    {:ok, other} = Pages.create(actor, %{type: "applet", private_owner_uid: ctx.agent})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, other.id, %{
        grants: [%{principal_uid: ctx.owner, role: "view"}]
      })

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("jobs.get_run", %{page_id: other.id, run_id: run_id}),
               ctx.ctx
             )
  end

  test "Job-scoped Binding reads use the executing colleague permissions on each source", ctx do
    actor = actor_fixture(ctx.agent)
    {:ok, applet} = Pages.create(actor, %{type: "applet", private_owner_uid: ctx.agent})

    publish_applet_fixture(
      %{actor: actor, page: applet},
      "export default {actions:{work:{idempotent:true,handler:()=>({ok:true})}}}"
    )

    {:ok, job} =
      Ankole.AutomationJobs.create_applet_job(actor, applet.id, "work", %{
        authorization_kind: "service"
      })

    {:ok, base} = Pages.create(actor, %{type: "base", private_owner_uid: ctx.agent})
    {:ok, table} = Ankole.Pod.Bases.create_table(actor, base.id, %{name: "Private source"})

    {:ok, binding} =
      Ankole.Signals.put_event_binding(actor, %{
        config_ref: "base://#{table.id}",
        automation_job_id: job.id
      })

    binding_id = binding.id
    assert {:ok, [%{id: ^binding_id}]} = Ankole.Signals.list_event_bindings(actor, nil, job.id)
    params = %{job_id: job.id}

    assert {:ok, %{"result" => [%{"id" => ^binding_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("bindings.list", params), ctx.ctx)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, applet.id, %{
        grants: [%{principal_uid: ctx.owner, role: "view"}]
      })

    assert {:ok, %{"result" => [%{"id" => ^binding_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("bindings.list", params), ctx.ctx)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.agent, base.id, %{
        grants: [%{principal_uid: ctx.owner, role: "view"}]
      })

    assert {:ok, %{"result" => [%{"id" => ^binding_id}]}} =
             RPCBroker.handle_read(ctx.ref, request("bindings.list", params), ctx.ctx)
  end

  test "a personal assistant reads only its Human's Applet Jobs and Run sources on a shared Page",
       ctx do
    owner = actor_fixture(ctx.owner)
    other = human_fixture().principal

    assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: ctx.owner
      }).principal

    route = "personal-job-broker-#{System.unique_integer([:positive])}"
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: assistant.uid})
    conversation_id = Ecto.UUID.generate()

    {:ok, _} =
      create_conversation_source(ctx.owner, %{
        conversation_id: conversation_id,
        agent_uid: assistant.uid,
        message_id: Ecto.UUID.generate(),
        text: "Inspect my personal Applet Job"
      })

    signal = Repo.one!(from(s in Signal, where: s.conversation_id == ^conversation_id))
    assert {:ok, _run} = Ankole.Sessions.Admission.admit(signal, signal)

    ref = %RunRef{
      agent_uid: assistant.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    rpc = %{route: route, worker_id: assistant.uid, request_id: "personal-job-read"}
    assert {:ok, actor} = RPCBroker.actor_for_request(ref, rpc)
    assert actor.principal.uid == assistant.uid
    assert Ankole.Principals.authority_uid(actor.principal.uid) == ctx.owner
    {:ok, page} = Pages.create(owner, %{type: "applet", private_owner_uid: ctx.owner})

    publish_applet_fixture(
      %{actor: owner, page: page},
      "export default {actions:{work:{idempotent:true,handler:()=>({ok:true})}}}"
    )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [
          %{principal_uid: assistant.uid, role: "contribute"},
          %{principal_uid: other.uid, role: "contribute"}
        ]
      })

    jobs =
      for human <- [owner, actor_fixture(other)] do
        {:ok, job} =
          Ankole.AutomationJobs.create_applet_job(human, page.id, "work", %{
            authorization_kind: "human"
          })

        {:ok, binding} =
          Ankole.Signals.put_event_binding(human, %{
            config_ref: "job://#{job.id}",
            automation_job_id: job.id
          })

        {:ok, %{runId: run_id}} =
          Ankole.Signals.applet_dispatch(
            %{"applet" => %{"pageId" => page.id}},
            page,
            human,
            human,
            "emit",
            [%{"targetJobId" => job.id, "type" => "manual"}]
          )

        {job.id, run_id, binding.id}
      end

    [{own_job, own_run, own_binding}, {other_job, other_run, _other_binding}] = jobs

    assert {:ok, %{"result" => [%{"id" => ^own_job, "human_uid" => human_uid}]}} =
             RPCBroker.handle_read(ref, request("jobs.list", %{page_id: page.id}), rpc)

    assert human_uid == ctx.owner

    assert {:ok, %{"result" => %{"id" => ^own_run, "automation_job_id" => ^own_job}}} =
             RPCBroker.handle_read(
               ref,
               request("jobs.get_run", %{page_id: page.id, run_id: own_run}),
               rpc
             )

    assert {:ok, %{"result" => [%{"id" => ^own_binding}]}} =
             RPCBroker.handle_read(
               ref,
               request("bindings.list", %{config_ref: "job://#{own_job}"}),
               rpc
             )

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_read(
               ref,
               request("jobs.get_run", %{page_id: page.id, run_id: other_run}),
               rpc
             )

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_read(
               ref,
               request("bindings.list", %{config_ref: "job://#{other_job}"}),
               rpc
             )
  end

  test "Binding reads of an Applet Job source retain its Page authorization", ctx do
    job = Ankole.WorkFixtures.applet_job(ctx.owner)
    reference = "job://#{job.id}"

    {:ok, binding} =
      Ankole.Signals.put_event_binding(actor_fixture(ctx.owner), %{
        config_ref: reference,
        automation_job_id: job.id
      })

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, job.page_id, %{
               grants: [%{principal_uid: ctx.agent, role: "view"}]
             })

    assert {:ok,
            %{
              "result" => [
                %{"id" => binding_id, "config_ref" => ^reference, "automation_job_id" => job_id}
              ]
            }} =
             RPCBroker.handle_read(
               ctx.ref,
               request("bindings.list", %{config_ref: reference}),
               ctx.ctx
             )

    assert binding_id == binding.id
    assert job_id == job.id

    outsider = Ankole.SessionsCase.agent_fixture().principal

    assert {:error, :forbidden} =
             Ankole.Signals.list_event_bindings(actor_fixture(outsider.uid), reference)
  end

  test "interactive and background Agents publish Action policies atomically with the live fence",
       ctx do
    {:ok, signal} = Ankole.Signals.get_signal(ctx.ref.signal_id)
    {background_job, job_ref} = start_job(ctx, signal)
    actor = actor_fixture(ctx.agent)
    source = "export default {actions:{work:{idempotent:false,handler:()=>1}}}"

    for {ref, close, closed_error} <- [
          {ctx.ref, fn -> Ankole.Sessions.Run.finalize(ctx.run, :silent) end, "run_closed"},
          {job_ref, fn -> complete_job(background_job) end,
           "background_agent_job_attempt_changed"}
        ] do
      {:ok, applet} = Pages.create(actor, %{type: "applet", private_owner_uid: ctx.agent})
      manifest = worker_applet_manifest(ctx.route, applet.id, source)
      params = %{id: applet.id, base_revision: 0, files: manifest}

      assert {:ok, %{"result" => %{"revision" => 1}}} =
               RPCBroker.handle_write(ref, request("applets.publish", params), ctx.ctx)

      {:ok, job} =
        Ankole.AutomationJobs.create_applet_job(actor, applet.id, "work", %{
          authorization_kind: "service"
        })

      updated_source = String.replace(source, "false", "true")
      updated_manifest = worker_applet_manifest(ctx.route, applet.id, updated_source)
      params = %{params | base_revision: 1, files: updated_manifest}

      assert {:ok, %{"result" => %{"revision" => 2}}} =
               RPCBroker.handle_write(ref, request("applets.publish", params), ctx.ctx)

      assert {:ok, %{idempotent: true}} = Ankole.AutomationJobs.get_automation_job(job.id)
      manifest = worker_applet_manifest(ctx.route, applet.id, source)

      assert {:error, %{"code" => "revision_conflict"}} =
               RPCBroker.handle_write(
                 ref,
                 request("applets.publish", %{params | files: manifest}),
                 ctx.ctx
               )

      assert {:ok, %{idempotent: true}} = Ankole.AutomationJobs.get_automation_job(job.id)
      close.()

      assert {:error, %{"code" => ^closed_error}} =
               RPCBroker.handle_write(
                 ref,
                 request("applets.publish", %{params | base_revision: 2, files: manifest}),
                 ctx.ctx
               )

      assert {:ok, %{idempotent: true}} = Ankole.AutomationJobs.get_automation_job(job.id)
      assert {:ok, %{revision: 2}} = Files.manifest(actor, applet.id)
      assert {:ok, _, ^updated_source} = Files.read(actor, applet.id, "server/main.js")
    end
  end

  test "Agents inspect, render, edit, and convert Office Pages through Pod RPC", ctx do
    owner = actor_fixture(ctx.owner)

    {:ok, word_page} =
      Ankole.Pod.OfficeFiles.create_blank(owner, %{
        format: "word",
        title: "Quarterly Memo",
        private_owner_uid: ctx.owner
      })

    {:ok, pres_page} =
      Ankole.Pod.OfficeFiles.create_blank(owner, %{
        format: "presentation",
        title: "Board Slides",
        private_owner_uid: ctx.owner
      })

    {:ok, sheet_page} =
      Ankole.Pod.OfficeFiles.create_blank(owner, %{
        format: "spreadsheet",
        title: "Revenue Model",
        private_owner_uid: ctx.owner
      })

    for page <- [word_page, pres_page, sheet_page] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
          grants: [%{principal_uid: ctx.agent, role: "edit"}]
        })
    end

    worker = WorkerFilesFake.start!(ctx.route, files: %{})

    assert {:ok, %{"result" => %{"format" => "word", "revision" => 1}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("office.inspect", %{id: word_page.id}),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"format" => "word", "commands" => word_commands}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("office.commands", %{id: word_page.id, query: "text.insert"}),
               ctx.ctx
             )

    assert Enum.any?(word_commands, &(&1["id"] == "text.insert"))

    assert {:ok, %{"result" => %{"revision" => 2, "format" => "word"}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("office.apply", %{
                 id: word_page.id,
                 base_revision: 1,
                 commands: [
                   %{"command" => "text.insert", "params" => %{"text" => "Executive Summary"}}
                 ]
               }),
               ctx.ctx
             )

    assert {:error, %{"code" => "revision_conflict"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("office.apply", %{
                 id: word_page.id,
                 base_revision: 1,
                 commands: [
                   %{"command" => "text.insert", "params" => %{"text" => "Stale"}}
                 ]
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"format" => "word", "index" => 1, "bytes" => png_bytes}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("office.render", %{
                 id: word_page.id,
                 page: 1,
                 home_relative_path: "renders/page-1.png"
               }),
               ctx.ctx
             )

    assert png_bytes > 0

    assert binary_part(WorkerFilesFake.files(worker)["renders/page-1.png"], 0, 8) ==
             <<137, 80, 78, 71, 13, 10, 26, 10>>

    assert {:ok,
            %{"result" => %{"format" => "presentation", "index" => 1, "bytes" => slide_bytes}}} =
             RPCBroker.handle_read(
               ctx.ref,
               request("office.render", %{
                 id: pres_page.id,
                 slide: 1,
                 home_relative_path: "renders/slide-1.png"
               }),
               ctx.ctx
             )

    assert slide_bytes > 0

    assert binary_part(WorkerFilesFake.files(worker)["renders/slide-1.png"], 0, 8) ==
             <<137, 80, 78, 71, 13, 10, 26, 10>>

    assert {:ok, %{"result" => %{"revision" => 2, "format" => "spreadsheet"}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("office.apply", %{
                 id: sheet_page.id,
                 ops: [%{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => "42"}]
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"page" => %{"id" => doc_id, "type" => "doc"}}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("office.to_document", %{id: word_page.id}),
               ctx.ctx
             )

    agent_actor = actor_fixture(ctx.agent)
    assert {:ok, %{content: %{plain_text: plain}}} = Pages.get(agent_actor, doc_id)
    assert plain =~ "Executive Summary"
  end

  defp worker_applet_manifest(route, page_id, source) do
    files = [
      {"src/main.tsx", "source"},
      {"dist/index.html", "frontend"},
      {"server/main.js", source}
    ]

    prefix = "build/#{page_id}/#{System.unique_integer([:positive])}/"

    WorkerFilesFake.start!(route,
      files: Map.new(files, fn {path, bytes} -> {prefix <> path, bytes} end)
    )

    Enum.map(files, fn {path, _} -> %{path: path, home_relative_path: prefix <> path} end)
  end

  defp knowledge_fixture(uid, title, type \\ :knowledge) do
    category = Ankole.BrainFixtures.category_fixture(uid)

    {:ok, page} =
      Pages.create(actor_fixture(uid), %{type: type, parent_id: category.id, title: title})

    page
  end

  defp request(operation, params),
    do: %FabricProto.PodRequest{operation: operation, params_json: Torque.encode!(params)}
end
