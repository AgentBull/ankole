defmodule Ankole.Connectors.Tokens do
  @moduledoc "Signs invocation and Turn contexts for the internal MCP gateway."
  alias Ankole.{Repo, SecretKeyBase}
  alias Ankole.Sessions.{RunRef, JobTurnRef}
  alias Ankole.AutomationJobs.AttemptRef
  @salt "connectors.runtime.v1"

  def invocation(context, caller, invocation_id, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    claims = %{
      "kind" => "applet",
      "tenant_id" => Repo.tenant_id!(),
      "invocation_id" => invocation_id,
      "page_id" => context["applet"]["pageId"],
      "caller_uid" => caller && caller.principal.uid,
      "authority" => encode_authority(caller && caller.turn_authority),
      "job" => context["job"],
      "run" => context["run"],
      "read_only" => context["read_only"] == true or context["method"] == "GET",
      "deadline_ms" => System.system_time(:millisecond) + remaining
    }

    with {:ok, caller_token} <- sign(Map.put(claims, "actor_mode", "caller"), remaining + 5_000),
         {:ok, admin_token} <- sign(Map.put(claims, "actor_mode", "admin"), remaining + 5_000) do
      {:ok,
       [
         {"x-ankole-caller-mcp-token", caller_token},
         {"x-ankole-admin-mcp-token", admin_token},
         {"x-ankole-mcp-origin", Ankole.WorkerFiles.Relay.origin()}
       ]}
    end
  end

  def worker(uid, ref) when is_struct(ref, RunRef) or is_struct(ref, JobTurnRef) do
    with :ok <- Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(ref, uid, :read),
         {:ok, endpoints} <-
           Ankole.AgentWorkers.Providers.connection_endpoints(Map.get(ref, :worker) || uid),
         {:ok, connections} <- connections(uid),
         {:ok, token} <-
           sign(
             %{
               "kind" => "worker",
               "tenant_id" => Repo.tenant_id!(),
               "agent_uid" => uid,
               "authority" => encode_authority({ref, uid}),
               "read_only" => false
             },
             3_600_000
           ) do
      {:ok,
       %{
         "ANKOLE_MCP_TOKEN" => token,
         "ANKOLE_MCP_CONNECTIONS" => Torque.encode!(connections),
         "ANKOLE_MCP_ORIGIN" => endpoints["relayOrigin"] || Ankole.WorkerFiles.Relay.origin()
       }}
    end
  end

  def worker(_, nil), do: {:ok, %{}}

  defp connections(uid) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid),
         {:ok, configs} <- Ankole.Connectors.list_auth_configs(principal),
         {:ok, accounts} <- Ankole.Connectors.Accounts.application_choices() do
      connections =
        for %{id: plugin, toolkits: toolkits} <- Ankole.Connectors.Registry.catalog(),
            toolkit <- toolkits,
            into: %{} do
          {toolkit,
           for(
             config <- configs,
             config.plugin_id == plugin and config.status == "active",
             do: %{
               connection: config.slug,
               label: config.display_name,
               accounts: Enum.sort(Map.get(accounts, config.id, []))
             }
           )}
        end

      {:ok, connections}
    end
  end

  def verify(token) when is_binary(token) do
    with {:ok, secret} <- SecretKeyBase.fetch(),
         {:ok, claims} <- Phoenix.Token.verify(secret, @salt, token, max_age: 3605),
         true <- claims["expires_at_ms"] > System.system_time(:millisecond),
         {:ok, _} <- Ecto.UUID.cast(claims["tenant_id"]) do
      {:ok, claims}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp sign(claims, ttl) do
    with {:ok, secret} <- SecretKeyBase.fetch(),
         do:
           {:ok,
            Phoenix.Token.sign(
              secret,
              @salt,
              Map.put(claims, "expires_at_ms", System.system_time(:millisecond) + ttl)
            )}
  end

  def encode_authority(nil), do: nil

  def encode_authority({%module{} = ref, uid}) when module in [RunRef, JobTurnRef, AttemptRef],
    do: %{
      "uid" => uid,
      "kind" => kind(module),
      "ref" => Map.new(Map.from_struct(ref), fn {key, value} -> {to_string(key), value} end)
    }

  def decode_authority(nil), do: nil

  def decode_authority(%{"uid" => uid, "kind" => kind, "ref" => values}) do
    module =
      case kind do
        "turn" -> RunRef
        "background_job" -> JobTurnRef
        "applet_attempt" -> AttemptRef
      end

    fields =
      Map.new(Map.from_struct(struct(module)), fn {key, _} -> {key, values[to_string(key)]} end)

    {struct!(module, fields), uid}
  end

  defp kind(RunRef), do: "turn"
  defp kind(JobTurnRef), do: "background_job"
  defp kind(AttemptRef), do: "applet_attempt"
end
