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
  Console route. `Ankole.Repo` stays the owner of the tenant: the action gets
  the same value that `AnkoleWeb.Plugs.PutDataContext` selected. A site route
  gets no tenant. The Principal of the session is the Ash actor, so that an
  action can record its operator (`context.actor`). Ash policies stay off, so
  no Ash authorization uses it.

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
      # J4 background agent jobs (v1: background_agent_job_controller.ex)
      {Ankole.BackgroundAgentJobs.Schemas.Job, :index, :console_list} =>
        {"background_agent_jobs", "read"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :get, :read} => {"background_agent_jobs", "read"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :route, :console_cancel} =>
        {"background_agent_jobs", "delete"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :route, :console_complete} =>
        {"background_agent_jobs", "update"},
      # J4 agent skill lessons (v1: agent_skill_lesson_controller.ex)
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :index, :console_list} =>
        {"agent:{agent_uid}:library", "read"},
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :route, :console_teach} =>
        {"agent:{agent_uid}:library", "update"},
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :route, :revoke} =>
        {"agent:{agent_uid}:library", "update"},
      # J4 agents (v1: agent_controller.ex)
      {Ankole.Principals.Agent, :index, :console_list} => {"agents", "read"},
      {Ankole.Principals.Agent, :get, :read} => {"agent:{uid}", "read"},
      {Ankole.Principals.Agent, :route, :console_create} => {"agents", "update"},
      {Ankole.Principals.Agent, :route, :console_update} => {"agent:{uid}", "update"},
      {Ankole.Principals.Agent, :route, :console_delete} => {"agent:{uid}", "delete"},
      {Ankole.Principals.Agent, :route, :console_enable} => {"agent:{uid}", "update"},
      # J4 agent workers (v1: agent_worker_controller.ex, worker_provider_controller.ex assign)
      {Ankole.AgentWorkers.AgentWorker, :index, :console_list} => {"agent_workers", "read"},
      {Ankole.AgentWorkers.AgentWorker, :route, :console_assign_provider} =>
        {"agent:{agent_uid}", "update"},
      # J4 ai-gateway conversations (v1: ai_gateway_conversation_controller.ex)
      {Ankole.AIGateway.Schemas.Conversation, :index, :console_list} =>
        {"ai_gateway_conversations", "read"},
      {Ankole.AIGateway.Schemas.Conversation, :get, :read} =>
        {"ai_gateway_conversations", "read"},
      {Ankole.AIGateway.Schemas.Message, :index, :console_list} =>
        {"ai_gateway_conversations", "read"}
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
