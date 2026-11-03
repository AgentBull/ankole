defmodule Ankole.Files.MetaVfsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Plug.Conn
  alias Ankole.AIAgent.Library.{Contracts, Skills}
  alias Ankole.Files.Vfs.Auth

  setup do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    {:ok, _} =
      Ankole.SessionsCase.admit_worker("meta-vfs-" <> Ecto.UUID.generate(), %{
        worker_id: agent.uid
      })

    {:ok, grant} = Auth.issue(agent.uid, nil)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    {:ok, skill} =
      Skills.create(actor_fixture(owner), %{
        slug: "vfs-demo",
        manifest_xml: "<page><p>Instruction</p></page>",
        metadata: %{"name" => "VFS", "description" => "VFS package"}
      })

    {:ok, skill} =
      Skills.put_file(actor_fixture(owner), skill.slug, "scripts/run.sh", "echo run\n", %{
        base_revision: skill.revision,
        mode: 0o755
      })

    {:ok, _} =
      Skills.set_binding(actor_fixture(owner), skill.slug, agent.uid, true)

    %{agent: agent, owner: owner, grant: grant}
  end

  test "Skills and effective contracts are readable with projected executable modes", ctx do
    assert request(ctx, "GET", "Skills/vfs-demo/SKILL.md").resp_body =~ "Instruction"
    script = request(ctx, "GET", "Skills/vfs-demo/scripts/run.sh")
    assert script.status == 200
    assert script.resp_body == "echo run\n"
    listing = request(ctx, "PROPFIND", "Skills/vfs-demo/scripts", "", [{"depth", "1"}])
    assert listing.status == 207
    assert listing.resp_body =~ "555"
    {:ok, effective} = Contracts.effective(ctx.agent.uid)
    assert request(ctx, "GET", "AGENTS.md").resp_body == effective["agents"]["content"]
    assert request(ctx, "GET", "DESIGN.md").resp_body == effective["design"]["content"]
  end

  test "every read-only root rejects direct and destination writes", ctx do
    for root <- ["Brain", "Skills", "AGENTS.md", "DESIGN.md"],
        method <- ["PUT", "POST", "MKCOL", "DELETE", "MOVE", "LOCK"] do
      response =
        request(ctx, method, root, "overwrite", [
          {"destination", "/api/v1/vfs/dav/AgentDrive/moved"}
        ])

      assert response.status == 403, "#{method} #{root}: #{response.status}"
    end

    assert request(ctx, "PUT", "AgentDrive/source.txt", "copy source").status == 201

    for root <- ["Brain", "Skills", "AGENTS.md", "DESIGN.md"] do
      response =
        request(ctx, "COPY", "AgentDrive/source.txt", "", [
          {"destination", "/api/v1/vfs/dav/#{root}/target"}
        ])

      assert response.status == 403
    end
  end

  test "listing a package checks its capability a bounded number of times and sees revocation",
       ctx do
    {:ok, skill} = Skills.get("vfs-demo")

    skill =
      Enum.reduce(1..20, skill, fn index, skill ->
        {:ok, skill} =
          Skills.put_file(
            actor_fixture(ctx.owner),
            skill.slug,
            "references/#{index}.md",
            "Reference",
            %{base_revision: skill.revision}
          )

        skill
      end)

    handler = "meta-package-listing-#{skill.id}"
    counter = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, meta, {pid, counter} ->
        if self() == pid and String.contains?(meta.query, ~s(FROM "skills")),
          do: :counters.add(counter, 1, 1)
      end,
      {self(), counter}
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    listing = request(ctx, "PROPFIND", "Skills/vfs-demo/references", "", [{"depth", "1"}])
    :telemetry.detach(handler)
    assert listing.status == 207
    for index <- 1..20, do: assert(listing.resp_body =~ "references/#{index}.md")
    assert :counters.get(counter, 1) <= 2

    {:ok, _} =
      Skills.set_binding(
        actor_fixture(ctx.owner),
        skill.slug,
        ctx.agent.uid,
        false
      )

    revoked = request(ctx, "GET", "Skills/vfs-demo/references/1.md")
    assert revoked.status == 404
    assert revoked.resp_body =~ "not_found"
  end

  test "switching recipients preserves identity capabilities while using a separate Brain scope",
       ctx do
    {:ok, payload} = Auth.decode(ctx.grant.token)

    for asker <- [ctx.owner, human_fixture().principal] do
      next =
        Map.put(payload, "disclosure", %{
          "mode" => "strict",
          "asker_uid" => asker.uid,
          "present_uids" => [asker.uid]
        })

      {:ok, token} = Ankole.SecretKeyBase.seal(Torque.encode!(next), "drive.vfs", [])
      scoped = %{ctx | grant: %{ctx.grant | token: token}}
      assert request(scoped, "GET", "Skills/vfs-demo/scripts/run.sh").resp_body == "echo run\n"
      assert request(scoped, "GET", "AGENTS.md").status == 200
    end
  end

  test "the warm capability mount does not depend on the original requester remaining active",
       ctx do
    {:ok, payload} = Auth.decode(ctx.grant.token)

    payload =
      Map.put(payload, "disclosure", %{
        "mode" => "strict",
        "asker_uid" => "departed",
        "present_uids" => ["departed"]
      })

    {:ok, token} = Ankole.SecretKeyBase.seal(Torque.encode!(payload), "drive.vfs", [])
    scoped = %{ctx | grant: %{ctx.grant | token: token}}

    assert request(scoped, "GET", "Skills/vfs-demo/SKILL.md", "", [{"x-ankole-library", "1"}]).status ==
             200

    assert request(scoped, "GET", "Brain", "", [{"x-ankole-library", "1"}]).status == 404
    assert {:ok, _} = Auth.refresh(payload, true)
  end

  defp request(ctx, method, path, body \\ "", headers \\ []) do
    Plug.Test.conn(method, "/api/v1/vfs/dav/" <> path, body)
    |> put_req_header("authorization", "Bearer " <> ctx.grant.token)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, c -> put_req_header(c, key, value) end)
    end)
    |> AnkoleWeb.Plugs.VfsWebdav.call([])
  end
end
