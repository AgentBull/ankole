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
  gets no tenant. The action context gets the Principal of the session under
  `:principal`, so that an action can record its operator. It is not an Ash
  actor: no Ash authorization uses it.

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
      # J5 brain (v1: brain_controller.ex)
      {Ankole.Brain.Schemas.Object, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Object, :route, :console_create} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_update} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :fork_library_page} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_rollback} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_forget} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :restore_object} => {"brain", "update"},
      {Ankole.Brain.Schemas.ObjectVersion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Claim, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Claim, :route, :console_supersede} => {"brain", "update"},
      {Ankole.Brain.Schemas.Claim, :route, :console_forget} => {"brain", "update"},
      {Ankole.Brain.Schemas.Claim, :route, :console_resolve} => {"brain", "update"},
      {Ankole.Brain.Schemas.Contradiction, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Contradiction, :route, :decide} => {"brain", "update"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :route, :console_approve} => {"brain", "update"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :route, :console_reject} => {"brain", "update"},
      {Ankole.Brain.Schemas.MergeSuggestion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.MergeSuggestion, :route, :console_approve} => {"brain", "update"},
      {Ankole.Brain.Schemas.MergeSuggestion, :route, :console_reject} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Source, :route, :console_register} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :update_default_scope} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :console_learn} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :archive_source} => {"brain", "update"}
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
      |> Ash.PlugHelpers.set_context(%{principal: conn.assigns[:current_principal]})
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
