defmodule Ankole.Pod.Applets do
  @moduledoc "Published Applet routes, called with the current principal's authority."

  alias Ankole.{Files, Repo}
  alias Ankole.Pod.Access
  alias Ankole.Pod.{Config, Pages}
  alias Ankole.Pod.Applets.Invocation

  @methods ~w(GET POST PUT PATCH DELETE)

  @doc "Starts one isolated invocation. The caller owns its cancellation lifetime."
  def start(%Ankole.AuthZ.Actor{} = actor, page_id, request, opts \\ []) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    Repo.tenant_id!()

    with :ok <- valid_request(request),
         {:ok, published} <- published(actor, page_id, Keyword.get(opts, :revision)),
         {:ok, principal} <- Access.principal(actor),
         {:ok, limits} <- Config.applet_limits(),
         {:ok, timezone} <- Ankole.SystemConfig.timezone() do
      context =
        request
        |> Map.take(["method", "path", "query", "body"])
        |> Map.merge(%{
          "principal" =>
            %{
              "uid" => uid,
              "name" => principal.display_name,
              "kind" => to_string(principal.type)
            }
            |> Map.reject(fn {_key, value} -> is_nil(value) end),
          "applet" => %{"pageId" => published.page_id, "revision" => published.revision},
          "read_only" => request["method"] == "GET" or Keyword.get(opts, :read_only, false),
          "timezone" => timezone
        })

      Invocation.start(
        published,
        context,
        limits,
        %{
          actor
          | turn_authority: Keyword.get(opts, :authority, actor.turn_authority)
        },
        authentication_ref: Keyword.get(opts, :authentication_ref)
      )
    end
  end

  @doc "Calls a route through the same isolated owner used by HTTP. Agent calls omit revision."
  def call(%Ankole.AuthZ.Actor{} = actor, page_id, request, opts \\ []) do
    with {:ok, task} <- start(actor, page_id, request, opts), do: Invocation.await(task)
  end

  # Capture one manifest/revision pair under the Page lock, then release the
  # database connection before downloading immutable source and environment bytes.
  defp published(%Ankole.AuthZ.Actor{} = actor, page_id, revision) do
    with {:ok, snapshot} <-
           Repo.transact_top_level(fn ->
             with {:ok, page} <- Pages.lock(page_id, :share),
                  {:ok, _page} <- Access.authorize(actor, page, "node_view", trash: false),
                  :ok <- applet_type(page),
                  do: package_snapshot_in_tx(page, revision)
           end),
         do: load_package(snapshot)
  end

  defp package_snapshot_in_tx(page, revision) do
    with {:ok, _owner} <- owner(page),
         :ok <- current_revision(page.revision, revision),
         {:ok, files} <- Ankole.Pod.Files.list_files(page.id),
         files = Map.new(files, &{&1.path, &1.object_id}),
         source_id when not is_nil(source_id) <- files["server/main.js"] do
      {:ok,
       %{
         tenant_id: Repo.tenant_id!(),
         page_id: page.id,
         revision: page.revision,
         owner_uid: page.owner_uid,
         source_id: source_id,
         env_id: files["applet.env.json"]
       }}
    else
      nil -> {:error, :route_not_found}
      error -> error
    end
  end

  defp load_package(snapshot) do
    with {:ok, source} <- Files.read_object(snapshot.source_id),
         {:ok, env} <-
           Ankole.Pod.Applets.Env.effective_env_from_object(snapshot.page_id, snapshot.env_id) do
      payload =
        source <>
          "\n" <>
          Torque.encode!(
            env
            |> Enum.sort_by(fn {key, _value} ->
              :unicode.characters_to_binary(key, :utf8, {:utf16, :big})
            end)
            |> Enum.map(fn {key, value} -> [key, value] end)
          )

      digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

      {:ok,
       snapshot
       |> Map.drop([:source_id, :env_id])
       |> Map.merge(%{source: source, env: env, sha256: digest})}
    end
  end

  @doc "Loads the current Action package; admission checks its revision before starting a slice."
  def action_package(page_id, contexts \\ [], timeout_ms \\ nil) do
    package =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(page_id, :share),
             :ok <- available(page),
             do: package_snapshot_in_tx(page, nil)
      end)

    with {:ok, snapshot} <- package,
         {:ok, package} <- load_package(snapshot),
         {:ok, limits} <- Config.action_limits(),
         inspection_limits =
           if(timeout_ms, do: Keyword.put(limits, :timeout_ms, timeout_ms), else: limits),
         {:ok, inspection} <-
           Ankole.FunctionRuntime.AppletClient.inspect(
             package.source,
             inspection_limits,
             package.env,
             contexts
           ) do
      {:ok,
       Map.merge(package, %{
         actions: inspection["actions"],
         concurrency_keys: inspection["concurrencyKeys"],
         limits: limits
       })}
    end
  end

  @doc "Inspects exported HTTP routes and background Actions on the published Applet package."
  def inspect_functions(%Ankole.AuthZ.Actor{} = actor, page_id) do
    snapshot =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(page_id, :share),
             {:ok, _page} <- Access.authorize(actor, page, "node_view", trash: false),
             :ok <- applet_type(page),
             :ok <- available(page),
             {:ok, files} <- Ankole.Pod.Files.list_files(page.id) do
          file_map = Map.new(files, &{&1.path, &1.object_id})

          case file_map["server/main.js"] do
            nil ->
              {:ok, {:frontend_only, page.revision}}

            source_id ->
              {:ok,
               {:backend,
                %{
                  tenant_id: Repo.tenant_id!(),
                  page_id: page.id,
                  revision: page.revision,
                  owner_uid: page.owner_uid,
                  source_id: source_id,
                  env_id: file_map["applet.env.json"]
                }}}
          end
        end
      end)

    case snapshot do
      {:ok, {:frontend_only, revision}} ->
        {:ok, %{has_backend: false, revision: revision, routes: [], actions: []}}

      {:ok, {:backend, raw}} ->
        with {:ok, package} <- load_package(raw),
             {:ok, limits} <- Config.action_limits(),
             {:ok, inspection} <-
               inspect_backend(package.source, limits, package.env) do
          {:ok,
           %{
             has_backend: true,
             revision: package.revision,
             routes: format_inspected_routes(inspection["routes"]),
             actions: format_inspected_actions(inspection["actions"])
           }}
        end

      error ->
        error
    end
  end

  defp inspect_backend(source, limits, env) do
    case Ankole.FunctionRuntime.AppletClient.inspect(source, limits, env, []) do
      {:ok, _} = ok ->
        ok

      {:error, %{"code" => "applet_busy"}} ->
        {:error, :applet_busy}

      {:error, %{"code" => "invalid_applet_routes", "message" => message}}
      when is_binary(message) ->
        {:error, {:invalid_applet_routes, %{reason: message}}}

      {:error, %{"code" => "invalid_applet_routes"}} ->
        {:error, :invalid_applet_routes}

      {:error, %{"code" => _}} ->
        {:error, :handler_error}

      {:error, _} = error ->
        error
    end
  end

  defp format_inspected_routes(routes) when is_list(routes) do
    Enum.flat_map(routes, fn
      key when is_binary(key) ->
        case String.split(key, " ", parts: 2) do
          [method, path] when method in @methods ->
            [%{method: parse_route_method(method), path: path}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp format_inspected_routes(_), do: []

  defp parse_route_method("GET"), do: :GET
  defp parse_route_method("POST"), do: :POST
  defp parse_route_method("PUT"), do: :PUT
  defp parse_route_method("PATCH"), do: :PATCH
  defp parse_route_method("DELETE"), do: :DELETE

  defp format_inspected_actions(actions) when is_map(actions) do
    actions
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, policy} ->
      %{
        key: key,
        concurrency: parse_concurrency(policy["concurrency"]),
        idempotent: policy["idempotent"] == true,
        max_slices: policy["maxSlices"] || 1000
      }
    end)
  end

  defp format_inspected_actions(_), do: []

  defp parse_concurrency("serial_fifo"), do: :serial_fifo
  defp parse_concurrency("serial_coalesce"), do: :serial_coalesce
  defp parse_concurrency(_), do: :parallel

  def authorize(actor, page_id, permission) do
    with {:ok, page} <- Pages.authorize(actor, page_id, permission),
         :ok <- available(page),
         do: {:ok, page}
  end

  def verify_package_in_tx(package) do
    with {:ok, page} <- Pages.lock(package.page_id, :share),
         :ok <- available(page),
         {:ok, _} <- owner(page),
         true <- page.revision == package.revision and page.owner_uid == package.owner_uid,
         do: {:ok, page},
         else: (
           false -> {:error, :applet_revision_changed}
           error -> error
         )
  end

  def invoke_action(package, context, actor) do
    with {:ok, task} <- Invocation.start(package, context, package.limits, actor),
         do: Invocation.await_execution(task)
  end

  def call_function(actor, page_id, request, parent) do
    deadline = parent["deadline"]
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, package} <- action_package(page_id, [], remaining),
         true <- Map.has_key?(package.actions, request["actionKey"]),
         {:ok, limits} <- Config.applet_limits() do
      limits =
        limits
        |> Keyword.put(:deadline, deadline)
        |> Keyword.put(:timeout_ms, max(1, deadline - System.monotonic_time(:millisecond)))

      context =
        parent
        |> Map.take(["job", "run", "timezone", "read_only"])
        |> Map.merge(%{
          "actionKey" => request["actionKey"],
          "signal" => %{"data" => request["data"] || %{}},
          "applet" => %{"pageId" => page_id, "revision" => package.revision},
          "principal" =>
            actor &&
              %{
                "uid" => Ankole.AuthZ.Actor.uid(actor),
                "kind" => to_string(actor.principal.type)
              }
        })

      with {:ok, task} <-
             Invocation.start(package, context, limits, actor,
               authentication_ref: parent["authentication_ref"]
             ),
           {:ok, outcome} <- Invocation.await(task) do
        if outcome["status"] < 400,
          do: {:ok, outcome["body"]},
          else:
            {:error,
             Map.new([:code, :message, :details, :retryable, :request_sent], fn key ->
               {key, get_in(outcome, ["body", "error", Atom.to_string(key)])}
             end)
             |> Map.put(:status, outcome["status"])}
      end
    else
      false -> {:error, if(remaining <= 0, do: :handler_timeout, else: :missing_action_key)}
      error -> error
    end
  end

  def available(%{id: id, deleted_at: nil, purge_started_at: nil, type: :applet}),
    do: if(Ankole.Pod.page_live?(id), do: :ok, else: {:error, :page_trashed})

  def available(%{type: :applet}), do: {:error, :page_trashed}
  def available(_), do: {:error, :not_found}

  def owner(%{owner_uid: nil}), do: {:error, :applet_owner_required}

  def owner(%{owner_uid: uid}) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, %{status: :active} = principal} -> {:ok, principal}
      _ -> {:error, :applet_owner_unavailable}
    end
  end

  def transfer_owner(actor, page_id, owner_uid) do
    Ankole.Repo.transact_top_level(fn ->
      with {:ok, _} <- Ankole.Principals.lock_principals_in_tx([owner_uid]),
           :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
           {:ok, _} <- Access.principal(actor),
           {:ok, page} <- Pages.lock(page_id),
           :ok <- applet_type(page),
           true <-
             page.owner_uid == Ankole.AuthZ.Actor.uid(actor) or
               Ankole.AuthZ.pod_admin?(Ankole.AuthZ.Actor.uid(actor)),
           {:ok, %{status: :active}} <- Ankole.Principals.get_principal(owner_uid) do
        Ankole.Ash.update(page, :transfer_owner, %{owner_uid: owner_uid})
      else
        false -> {:error, :forbidden}
        {:error, _} = error -> error
        _ -> {:error, :applet_owner_unavailable}
      end
    end)
  end

  defp applet_type(%{type: :applet}), do: :ok
  defp applet_type(_), do: {:error, :not_found}

  defp current_revision(_current, nil), do: :ok
  defp current_revision(revision, revision), do: :ok

  defp current_revision(current, _revision),
    do: {:error, {:applet_revision_changed, %{revision: current}}}

  defp valid_request(%{"method" => method, "path" => "/" <> _, "query" => query})
       when method in @methods and is_map(query) do
    if Enum.all?(query, fn {key, value} ->
         query_string?(key) and
           (query_string?(value) or (is_list(value) and Enum.all?(value, &query_string?/1)))
       end), do: :ok, else: {:error, :invalid_request}
  end

  defp valid_request(_), do: {:error, :invalid_request}
  defp query_string?(value), do: is_binary(value) and String.valid?(value)
end
