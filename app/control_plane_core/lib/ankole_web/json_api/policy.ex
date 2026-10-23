defmodule AnkoleWeb.JSONAPI.Policy do
  @moduledoc """
  Authorizes each JSON:API route through Principal/AuthZ.

  Ash policies stay disabled: Principal/AuthZ is the only authorization model.
  Each route of a JSON:API router has one rule in `@rules`. A rule gives the
  AuthZ resource and action that `AnkoleWeb.ConsolePolicy.authorize/3` checks,
  the same pair that the v1 controller of the route checks. The AuthZ resource
  can contain `{name}` for the value of a path parameter. A route without a
  rule is refused. `AnkoleWeb.JSONAPI.PolicyTest` asserts that each route has
  a rule and that each rule has a route.

  The policy also gives the tenant of `Ankole.Repo` to the Ash action of a
  Console route, and the Console Principal as the actor of the action. Ash
  policies stay disabled, so the actor only tells the action who operates.
  `Ankole.Repo` stays the owner of the tenant: the action gets the same value
  that `AnkoleWeb.Plugs.PutDataContext` selected. A site route gets no tenant.

  `AshJsonApi.Router` calls the controller of a route also after a halted
  `before_dispatch`. Thus a refusal throws the refused connection, and the
  `call/2` of `AnkoleWeb.JSONAPI.Router` returns it.
  """

  import Plug.Conn

  alias AnkoleWeb.ConsolePolicy

  @type scope :: :site | :console
  @type rule_key :: {module(), atom(), atom()}
  @type rule :: {authz_resource :: String.t(), authz_action :: String.t()}

  # {resource, route type, action or relationship} => {AuthZ resource, AuthZ action}
  @rules %{
    site: %{},
    console: %{
      # J3 automation jobs (v1: automation_job_controller.ex)
      {Ankole.AutomationJobs.Schemas.Job, :index, :console_list} => {"automation_jobs", "read"},
      {Ankole.AutomationJobs.Schemas.Job, :get, :read} =>
        {"agent:{agent_uid}:automation_jobs", "read"},
      {Ankole.AutomationJobs.Schemas.Run, :index, :console_list} =>
        {"agent:{agent_uid}:automation_jobs", "read"},
      # J3 OIDC clients (v1: oidc_client_controller.ex)
      {Ankole.OIDC.Client, :index, :console_list} => {"oidc_clients", "read"},
      {Ankole.OIDC.Client, :route, :console_create} => {"oidc_clients", "update"},
      {Ankole.OIDC.Client, :get, :read} => {"oidc_client:{id}", "read"},
      {Ankole.OIDC.Client, :route, :console_update} => {"oidc_client:{id}", "update"},
      {Ankole.OIDC.Client, :route, :console_delete} => {"oidc_client:{id}", "delete"},
      {Ankole.OIDC.LogoutDelivery, :index, :console_list} => {"oidc_client:{client_id}", "read"},
      {Ankole.OIDC.LogoutDelivery, :route, :console_retry} =>
        {"oidc_client:{client_id}", "update"},
      # J3 webhook endpoints (v1: webhook_endpoint_controller.ex)
      {Ankole.Signals.WebhookEndpoint, :index, :console_list} => {"webhooks", "read"},
      {Ankole.Signals.WebhookEndpoint, :route, :create_operator_endpoint} =>
        {"webhooks", "update"},
      {Ankole.Signals.WebhookEndpoint, :route, :cancel_operator_endpoint} =>
        {"webhooks", "delete"},
      # J3 cron schedules and checkbacks (v1: schedule_controller.ex)
      {Ankole.Schedule.Schemas.CronSchedule, :index, :console_list} => {"schedules", "read"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_create} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :get, :read} =>
        {"agent:{agent_uid}:schedules", "read"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_update} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_pause} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_resume} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_remove} =>
        {"agent:{agent_uid}:schedules", "delete"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_run} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :index, :console_cron_runs} =>
        {"agent:{agent_uid}:schedules", "read"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :index, :console_checkbacks} =>
        {"schedules", "read"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :route, :console_cancel_checkback} =>
        {"agent:{agent_uid}:schedules", "delete"},
      # J3 signal bindings (v1: signal_binding_controller.ex)
      {Ankole.Signals.Binding, :route, :console_disable} =>
        {"agent:{agent_uid}:signal_bindings", "delete"},
      # J2 identity (v1: principal_controller.ex, authz_group_controller.ex,
      # permission_grant_controller.ex, identity_mapping_request_controller.ex)
      {Ankole.Principals.Principal, :index, :console_list} => {"principals", "read"},
      {Ankole.Principals.Principal, :get, :read} => {"principal:{uid}", "read"},
      {Ankole.Principals.Principal, :post, :create_local_user} => {"principals", "update"},
      {Ankole.Principals.Principal, :patch, :update_human} => {"principal:{uid}", "update"},
      {Ankole.Principals.MappingRequest, :index, :console_list} =>
        {"identity_mapping_requests", "read"},
      {Ankole.Principals.MappingRequest, :delete, :delete_in_tx} =>
        {"identity_mapping_requests", "update"},
      {Ankole.Principals.MappingRequest, :route, :bind_request} =>
        {"identity_mapping_requests", "update"},
      {Ankole.Principals.MappingRequest, :route, :bind_subject} =>
        {"identity_mapping_requests", "update"},
      {Ankole.AuthZ.Group, :index, :console_list} => {"principal_groups", "read"},
      {Ankole.AuthZ.Group, :post, :create} => {"principal_groups", "update"},
      {Ankole.AuthZ.Group, :route, :preview_computed_members} => {"principal_groups", "read"},
      {Ankole.AuthZ.Group, :get, :read} => {"principal_group:{name}", "read"},
      {Ankole.AuthZ.Group, :patch, :update} => {"principal_group:{name}", "update"},
      {Ankole.AuthZ.Group, :delete, :delete_operator_group} =>
        {"principal_group:{name}", "delete"},
      {Ankole.AuthZ.Group, :route, :list_members} => {"principal_group:{name}:members", "read"},
      {Ankole.AuthZ.Group, :route, :add_member} => {"principal_group:{name}:members", "update"},
      {Ankole.AuthZ.Group, :route, :remove_member} =>
        {"principal_group:{name}:members", "update"},
      {Ankole.AuthZ.Group, :index, :of_principal} => {"principal:{uid}:groups", "read"},
      {Ankole.AuthZ.Grant, :index, :of_principal} => {"principal:{uid}:grants", "read"},
      {Ankole.AuthZ.Grant, :index, :of_group} => {"principal_group:{name}:grants", "read"},
      {Ankole.AuthZ.Grant, :post, :create_operator_grant} => {"permission_grants", "update"},
      {Ankole.AuthZ.Grant, :get, :by_id} => {"permission_grant:{id}", "read"},
      {Ankole.AuthZ.Grant, :patch, :update_operator_grant} => {"permission_grant:{id}", "update"},
      {Ankole.AuthZ.Grant, :delete, :delete_operator_grant} => {"permission_grant:{id}", "delete"}
    }
  }

  @doc "Gives the rules of the routers of one scope."
  @spec rules(scope()) :: %{rule_key() => rule()}
  def rules(scope), do: Map.fetch!(@rules, scope)

  @doc """
  Gives the rule key of a route: the resource, the route type, and the
  relationship of a relationship route or else the action.
  """
  @spec rule_key(module(), AshJsonApi.Resource.Route.t()) :: rule_key()
  def rule_key(resource, route), do: {resource, route.type, route.relationship || route.action}

  @doc """
  The `before_dispatch` function of a JSON:API router.

  The OpenAPI document and the response for an unknown path need no rule.
  AshJsonApi sends the OpenAPI document without a content type, so this
  function sets it. A test router can give its own rules.
  """
  def before_dispatch(conn, route_info, scope, rules \\ nil)

  def before_dispatch(conn, :open_api, _scope, _rules),
    do: put_resp_content_type(conn, "application/json")

  def before_dispatch(conn, :not_found, _scope, _rules), do: conn

  def before_dispatch(
        conn,
        %{resource: resource, route: route, params: params},
        scope,
        rules
      ) do
    with {:ok, {authz_resource, action}} <-
           Map.fetch(rules || rules(scope), rule_key(resource, route)),
         :ok <- ConsolePolicy.authorize(conn, expand(authz_resource, params), action) do
      conn
      |> Ash.PlugHelpers.set_tenant(tenant(scope))
      |> Ash.PlugHelpers.set_actor(conn.assigns[:current_principal])
    else
      _refused -> refuse(conn)
    end
  end

  def before_dispatch(conn, _route_info, _scope, _rules), do: refuse(conn)

  @doc "Gives the refused connection of a `before_dispatch` call, or the result of `call`."
  @spec dispatch(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  def dispatch(conn, call) do
    call.(conn)
  catch
    {__MODULE__, %Plug.Conn{} = refused} -> refused
  end

  defp tenant(:site), do: nil
  defp tenant(:console), do: Ankole.Repo.tenant_id()

  defp expand(authz_resource, params) do
    Regex.replace(~r/\{(\w+)\}/, authz_resource, fn _match, name -> Map.fetch!(params, name) end)
  end

  defp refuse(conn) do
    body =
      AshJsonApi.Serializer.serialize_errors(nil, %AshJsonApi.Error{
        status_code: 403,
        code: "forbidden",
        title: "Forbidden",
        detail: "access denied"
      })

    refused =
      conn
      |> put_resp_content_type("application/vnd.api+json")
      |> send_resp(403, body)
      |> halt()

    throw({__MODULE__, refused})
  end
end
