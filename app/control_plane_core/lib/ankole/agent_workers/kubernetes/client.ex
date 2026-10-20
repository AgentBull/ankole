defmodule Ankole.AgentWorkers.Kubernetes.Client do
  @moduledoc "Kubernetes requests with provider credentials, complete lists, and platform errors."

  alias Ankole.AgentWorkers.Providers.YAML

  @doc "The selected kubeconfig context; it is never written to a temporary file."
  def kubeconfig(text) do
    with {:ok, data, _locations} <- YAML.parse(text),
         true <-
           is_list(data["clusters"]) and is_list(data["users"]) and is_list(data["contexts"]),
         context when is_binary(context) <- data["current-context"] do
      config =
        Kubereq.Kubeconfig.new!(
          clusters: data["clusters"],
          users: data["users"],
          contexts: data["contexts"]
        )
        |> Kubereq.Kubeconfig.set_current_context(context)

      case config.current_cluster do
        %{"server" => server} when is_binary(server) and server != "" -> {:ok, config}
        _invalid -> {:error, :invalid_worker_provider_kubeconfig}
      end
    else
      _invalid -> {:error, :invalid_worker_provider_kubeconfig}
    end
  rescue
    _error in [ArgumentError, KeyError, FunctionClauseError, BadMapError] ->
      {:error, :invalid_worker_provider_kubeconfig}
  end

  def create(provider, resource) do
    call(provider, fn req -> Kubereq.create(req, resource) end)
    |> case do
      {:ok, %{status: status, body: body}} when status in [200, 201, 202] -> {:ok, body}
      other -> error(other)
    end
  end

  def get(provider, kind, name, opts \\ []) do
    call(provider, fn req ->
      Kubereq.get(
        req,
        provider.settings["namespace"],
        name,
        Keyword.merge([api_version: "v1", kind: kind], opts)
      )
    end)
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:ok, nil}
      other -> error(other)
    end
  end

  def delete(provider, kind, name, opts \\ []) do
    call(provider, fn req ->
      Kubereq.delete(
        req,
        provider.settings["namespace"],
        name,
        Keyword.merge([api_version: "v1", kind: kind], opts)
      )
    end)
    |> case do
      {:ok, %{status: status}} when status in [200, 202, 404] -> :ok
      other -> error(other)
    end
  end

  def list(provider, kind, opts \\ []), do: list_page(provider, kind, opts, [], nil)

  defp list_page(provider, kind, opts, acc, continue) do
    opts =
      if continue,
        do:
          Keyword.update(
            opts,
            :params,
            [continue: continue],
            &Keyword.put(&1, :continue, continue)
          ),
        else: opts

    call(provider, fn req ->
      Kubereq.list(
        req,
        provider.settings["namespace"],
        Keyword.merge([api_version: "v1", kind: kind], opts)
      )
    end)
    |> case do
      {:ok, %{status: 200, body: %{"items" => items} = body}} ->
        acc = [items | acc]

        case get_in(body, ["metadata", "continue"]) do
          next when is_binary(next) and next != "" -> list_page(provider, kind, opts, acc, next)
          _done -> {:ok, acc |> Enum.reverse() |> List.flatten()}
        end

      other ->
        error(other)
    end
  end

  defp call(provider, fun) do
    options = Application.get_env(:ankole, :kubereq, [])

    kubeconfig =
      case provider.secrets["kubeconfig"] do
        nil ->
          Kubereq.Kubeconfig.ServiceAccount

        text ->
          {:ok, config} = kubeconfig(text)
          config
      end

    req =
      Req.new(retry: false, receive_timeout: 30_000)
      |> Kubereq.attach(Keyword.put_new(options, :kubeconfig, kubeconfig))

    fun.(req)
  rescue
    error in Kubereq.Error.KubeconfError ->
      {:error, {:kubernetes_credentials, Exception.message(error)}}
  end

  defp error({:ok, %{status: status, body: body}}),
    do: {:error, {:kubernetes_api, status, message(body)}}

  defp error({:error, reason}), do: {:error, {:kubernetes_request, reason}}
  defp message(%{"message" => message}), do: message
  defp message(body), do: inspect(body) |> String.slice(0, 500)
end
