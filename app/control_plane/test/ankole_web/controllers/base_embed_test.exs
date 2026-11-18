defmodule AnkoleWeb.BaseEmbedTest do
  use AnkoleWeb.ConnCase

  @portal "https://portal.example.com"

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    %{path: "/embed/pages/" <> Ankole.Kernel.uuid_shorten(Ankole.Kernel.gen_uuid_v7())}
  end

  defp allow(tenant, origins) do
    Ankole.Repo.with_tenant(tenant.id, fn ->
      Ankole.AppConfigure.put_tenant_by_key("pod.embed_origins", origins)
    end)
  end

  defp frame_policy(response), do: get_resp_header(response, "content-security-policy")

  test "an allowed origin may frame the Base embed, and the shell names it for the bridge", %{
    conn: conn,
    tenant: tenant,
    path: path
  } do
    assert {:ok, [@portal]} = allow(tenant, [@portal <> "/"])

    response = conn |> pod_conn(tenant) |> active_admin_conn() |> get(path)
    html = html_response(response, 200)

    source = Application.fetch_env!(:ankole, :webapp_entries) |> Map.fetch!("base-embed")
    assert html =~ "http://assets.test/#{String.trim_leading(source, "/")}"
    assert html =~ ~s(<meta name="ankole-embed-origins" content="[&quot;#{@portal}&quot;]">)
    assert frame_policy(response) == ["base-uri 'self'; frame-ancestors 'self' #{@portal};"]
  end

  test "an origin outside the list may not frame the Base embed", %{
    conn: conn,
    tenant: tenant,
    path: path
  } do
    response = conn |> pod_conn(tenant) |> active_admin_conn() |> get(path)

    assert html_response(response, 200) =~ ~s(<meta name="ankole-embed-origins" content="[]">)
    assert frame_policy(response) == ["base-uri 'self'; frame-ancestors 'self';"]
  end

  test "a browser without a Pod session gets the embed shell with 401 instead of a sign-in redirect",
       %{conn: conn, tenant: tenant, path: path} do
    assert {:ok, _} = allow(tenant, [@portal])

    response = conn |> pod_conn(tenant) |> get(path)
    html = html_response(response, 401)

    assert get_resp_header(response, "location") == []
    assert html =~ ~s(<meta name="ankole-response-status" content="401">)
    refute html =~ ~s(<meta name="ankole-principal")
    assert frame_policy(response) == ["base-uri 'self'; frame-ancestors 'self' #{@portal};"]
  end

  test "every other Pod page still refuses to be framed by another origin", %{
    conn: conn,
    tenant: tenant
  } do
    assert {:ok, _} = allow(tenant, [@portal])
    page = "/pages/" <> Ankole.Kernel.uuid_shorten(Ankole.Kernel.gen_uuid_v7())

    response = conn |> pod_conn(tenant) |> active_admin_conn() |> get(page)

    assert html_response(response, 200)
    assert frame_policy(response) == ["base-uri 'self'; frame-ancestors 'self';"]
  end

  test "the operator lists origins as scheme, host, and optional port", %{tenant: tenant} do
    assert {:ok, ["https://portal.example.com:8443", "http://localhost:5173"]} =
             allow(tenant, ["https://portal.example.com:8443/", "http://localhost:5173"])

    for invalid <- [["portal.example.com"], ["https://portal.example.com/tables"], ["*"], "x"] do
      assert {:error, _} = allow(tenant, invalid)
    end
  end
end
