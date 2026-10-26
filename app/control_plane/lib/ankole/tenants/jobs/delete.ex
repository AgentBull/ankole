defmodule Ankole.Tenants.Jobs.Delete do
  @moduledoc "Resumable tenant teardown through the Agent Worker lifecycle owner."
  use Ankole.Job,
    tenancy: :site,
    queue: :default,
    max_attempts: 20,
    unique: [period: :infinity, keys: [:tenant_id], states: [:available, :scheduled, :retryable]]

  import Ecto.Query
  require Ash.Query
  alias Ankole.{Principals, Repo, Tenants}
  alias Ankole.Principals.Principal
  alias Ankole.AgentWorkers.AgentWorker

  # Child rows precede their parents. This order comes from the migration's
  # PostgreSQL foreign keys; Agent and Worker rows use their lifecycle owner.
  @tables ~w(
    base_records base_views base_fields base_tables
    page_user_states page_changes page_contents permission_grants pages
    external_message_refs conversation_messages conversation_participants
    cron_schedules session_ambient_judgments scheduled_events
    sessions agent_computer_worker_envs drive_files
    agent_library_container_entries agent_plugin_overrides agent_skill_lessons agent_skills
    ai_gateway_artifacts ai_gateway_compaction_artifacts ai_gateway_usage_records
    app_configurations automation_job_runs signal_webhook_endpoints
    background_agent_job_turn_items brain_chunks brain_take_domain_assignments
    brain_contradictions brain_links brain_merge_suggestions brain_object_aliases
    brain_object_versions brain_timelines brain_slug_aliases brain_tags brain_schema_suggestions
    brain_schema_calibration_domains brain_schema_link_types brain_schema_types
    brain_sources authn_challenges browser_pod_authentications browser_authentications browser_login_transactions session_tool_receipts session_round_states
    human_access_events human_access_restrictions principal_site_credentials pod_invitations
    identity_directory_events identity_directory_states identity_mapping_requests
    oidc_authorization_codes oidc_client_groups oidc_refresh_tokens oidc_refresh_token_families oidc_logout_requests
    oidc_logout_deliveries principal_external_identities
    principal_group_external_bindings principal_group_memberships deliveries
    conversation_inbound_batches conversation_input_tombstones signal_bindings
    workflow_agent_calls delivery_previews signals ai_gateway_messages automation_jobs
    background_agent_job_turns brain_claims brain_schema_packs oidc_sessions conversations principal_groups
    workflow_runs ai_gateway_conversations background_agent_jobs brain_objects
    oidc_clients human_users
  )
  # Keep cleanup's completion evidence and its referenced Human until the
  # final transaction removes both; earlier batches must not erase the proof.
  @batch_tables @tables -- ["human_access_events", "human_users"]

  if Mix.env() == :test do
    @doc false
    def tenant_tables, do: @tables ++ ["principals", "agents", "agent_workers"]
  end

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"tenant_id" => id}}) do
    case Tenants.get(id) do
      {:error, :not_found} -> :ok
      {:ok, %{deleting_at: nil}} -> {:cancel, :tenant_not_deleting}
      {:ok, tenant} -> Repo.with_tenant(tenant.id, fn -> step(tenant) end)
    end
  end

  defp step(tenant) do
    humans =
      Principals.list_principals!(query: [filter: [type: :human, status: :active], limit: 50])

    if humans != [] do
      disable_humans(humans)
    else
      # Human cleanup must commit while its Principal still exists. Merely
      # enqueueing WorkCleanup would let deletion erase that job's input first.
      with :ok <- cleanup_human_work() do
        agents = Principals.list_principals!(query: [filter: [type: :agent], limit: 50])

        cond do
          agents != [] ->
            delete_agents(agents)

          Repo.exists?(AgentWorker) ->
            {:snooze, 5}

          delete_batches(tenant.id, @batch_tables, System.monotonic_time(:millisecond) + 1_000) ->
            {:snooze, 1}

          true ->
            finish(tenant)
        end
      end
    end
  end

  defp cleanup_human_work do
    case Ankole.Principals.WorkCleanup.pending_for_tenant(50) do
      [] ->
        :ok

      humans ->
        Enum.reduce_while(humans, {:snooze, 1}, fn principal, result ->
          case Ankole.Principals.WorkCleanup.cleanup(principal.uid, principal.access_version) do
            {:ok, _} -> {:cont, result}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp disable_humans(humans) do
    with {:ok, system} <- Principals.system_principal() do
      actor = Ankole.ActorRef.from_principal(system)

      Enum.reduce_while(humans, {:snooze, 1}, fn principal, result ->
        case Ankole.Principals.HumanAccess.disable(
               principal.uid,
               "tenant_deleting",
               actor,
               Ash.UUIDv7.generate()
             ) do
          {:ok, _} -> {:cont, result}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp delete_agents(agents) do
    Enum.reduce_while(agents, {:snooze, 1}, fn principal, result ->
      case Ankole.Principals.delete_agent(principal.uid) do
        {:ok, _} -> {:cont, result}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp delete_batches(_tenant_id, [], _deadline), do: false

  defp delete_batches(tenant_id, [table | remaining] = tables, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      true
    else
      %{num_rows: count} = delete_batch(tenant_id, table)
      delete_batches(tenant_id, if(count > 0, do: tables, else: remaining), deadline)
    end
  end

  # Delete leaves first so one parent cannot cascade through an unbounded subtree.
  defp delete_batch(tenant_id, "pages") do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      DELETE FROM pages WHERE tenant_id = $1::text::uuid AND ctid IN (
        SELECT page.ctid FROM pages AS page
        WHERE page.tenant_id = $1::text::uuid AND NOT EXISTS (
          SELECT 1 FROM pages AS child
          WHERE child.tenant_id = page.tenant_id AND child.parent_id = page.id
        ) LIMIT 200
      )
      """,
      [tenant_id]
    )
  end

  defp delete_batch(tenant_id, table) when table in ["permission_grants", "principal_groups"] do
    {:ok, result} =
      Repo.transact(fn ->
        Ankole.Pod.Pages.lock_tree()
        {:ok, delete_rows(tenant_id, table)}
      end)

    result
  end

  defp delete_batch(tenant_id, table), do: delete_rows(tenant_id, table)

  defp delete_rows(tenant_id, table) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM #{table} WHERE tenant_id = $1::text::uuid AND ctid IN (SELECT ctid FROM #{table} WHERE tenant_id = $1::text::uuid LIMIT 200)",
      [tenant_id]
    )
  end

  defp finish(tenant) do
    {:ok, :ok} = Ankole.Pod.BaseRepo.delete_tenant(tenant.base_db_id)

    case Repo.transact(fn -> finish_in_tx(tenant) end) do
      {:ok, :finished} -> :ok
      {:ok, :resources_pending} -> {:snooze, 1}
      {:error, _} = error -> error
    end
  end

  defp finish_in_tx(tenant) do
    Ankole.Pod.Pages.lock_tree()

    case Tenants.Tenant
         |> Ash.Query.filter(id == ^tenant.id)
         |> Ash.Query.lock(:for_update)
         |> Ankole.Ash.read_one!() do
      nil ->
        {:ok, :finished}

      locked ->
        # A request admitted before deletion can create another Agent. The
        # tenant lock closes that race before final deletion can bypass cleanup.
        if Repo.exists?(
             from p in Principal,
               where: p.type == :agent or (p.type == :human and p.status == :active)
           ) or
             Repo.exists?(AgentWorker) or
             Ankole.Principals.WorkCleanup.pending_for_tenant(1) != [] do
          {:ok, :resources_pending}
        else
          for table <- @tables ++ ["principals"] do
            Ecto.Adapters.SQL.query!(
              Repo,
              "DELETE FROM #{table} WHERE tenant_id = $1::text::uuid",
              [tenant.id]
            )
          end

          {:ok, _} = Ankole.Ash.destroy(locked, :delete_in_tx)
          {:ok, _} = Ankole.Files.Jobs.CollectUnreferenced.new(%{}) |> Oban.insert()
          {:ok, :finished}
        end
    end
  end
end
