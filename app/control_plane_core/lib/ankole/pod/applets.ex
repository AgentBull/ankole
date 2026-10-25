defmodule Ankole.Pod.Applets do
  @moduledoc "Published Applet routes, called with the current principal's authority."

  alias Ankole.{Files, Repo}
  alias Ankole.Pod.{Access, Config, Pages}
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
          "timezone" => timezone
        })

      Invocation.start(published, context, limits, %{
        actor
        | turn_authority: Keyword.get(opts, :authority, actor.turn_authority)
      })
    end
  end

  @doc "Calls a route through the same isolated owner used by HTTP. Agent calls omit revision."
  def call(%Ankole.AuthZ.Actor{} = actor, page_id, request, opts \\ []) do
    with {:ok, task} <- start(actor, page_id, request, opts), do: Invocation.await(task)
  end

  # A page lock gives this read one manifest/revision pair even when a publisher commits.
  # Read immutable content before releasing it: file replacement and GC cannot change the package.
  defp published(%Ankole.AuthZ.Actor{} = actor, page_id, revision) do
    Repo.transact_top_level(fn -> published_in_tx(actor, page_id, revision) end)
  end

  @doc false
  def published_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id, revision) do
    with {:ok, page} <- Pages.lock(page_id, :share),
         {:ok, _page} <- Pages.authorize(actor, page.id, "page_view"),
         :ok <- applet_type(page),
         :ok <- current_revision(page.revision, revision),
         {:ok, source} <- backend_source(page.id),
         {:ok, env} <- backend_environment(page.id) do
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
       %{
         tenant_id: Repo.tenant_id!(),
         page_id: page.id,
         revision: page.revision,
         source: source,
         env: env,
         sha256: digest
       }}
    end
  end

  defp applet_type(%{type: :applet}), do: :ok
  defp applet_type(_), do: {:error, :not_found}

  defp backend_source(id) do
    with {:ok, file} <- Files.fetch(:pod, Ankole.Pod.Files.prefix(id) <> "/server/main.js"),
         {:ok, source} <- Files.read_content(Base.encode16(file.sha256, case: :lower)),
         do: {:ok, source},
         else: (
           {:error, :not_found} -> {:error, :route_not_found}
           error -> error
         )
  end

  defp backend_environment(id) do
    case Files.fetch(:pod, Ankole.Pod.Files.prefix(id) <> "/applet.env.json") do
      {:ok, file} ->
        with {:ok, bytes} <- Files.read_content(Base.encode16(file.sha256, case: :lower)),
             do: Torque.decode(bytes)

      {:error, :not_found} ->
        {:ok, %{}}

      error ->
        error
    end
  end

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
