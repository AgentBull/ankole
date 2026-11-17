defmodule Ankole.SiteConsole.Aggregates.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  import Ecto.Query

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: BackgroundJob
  alias Ankole.Principals.{Agent, HumanUser, Principal, ServiceAccount}
  alias Ankole.Repo
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Signals.Binding
  alias Ankole.Tenants.Tenant

  @impl true
  def run(%{action: %{name: name}, arguments: args}, _opts, _context) do
    {:ok, Repo.across_tenants(fn -> dispatch(name, args) end)}
  end

  defp dispatch(:overview, _args) do
    tenant_counts =
      Repo.one(
        from(t in Tenant,
          where: is_nil(t.deleting_at),
          select: %{
            active: count(fragment("CASE WHEN ? IS NULL THEN 1 END", t.suspended_at)),
            suspended: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", t.suspended_at))
          }
        )
      ) || %{active: 0, suspended: 0}

    agent_counts =
      Repo.one(
        from(a in Agent,
          join: t in Tenant,
          on: t.id == a.tenant_id and is_nil(t.deleting_at),
          join: p in Principal,
          on: p.tenant_id == a.tenant_id and p.uid == a.uid,
          select: %{
            active: count(fragment("CASE WHEN ? = 'active' THEN 1 END", p.status)),
            disabled: count(fragment("CASE WHEN ? = 'disabled' THEN 1 END", p.status))
          }
        )
      ) || %{active: 0, disabled: 0}

    worker_counts =
      Repo.one(
        from(w in AgentWorker,
          join: t in Tenant,
          on: t.id == w.tenant_id and is_nil(t.deleting_at),
          select: %{
            ready: count(fragment("CASE WHEN ? = 'ready' THEN 1 END", w.state)),
            starting:
              count(fragment("CASE WHEN ? IN ('starting', 'draining') THEN 1 END", w.state)),
            unhealthy:
              count(
                fragment(
                  "CASE WHEN ? = 'stale' OR ? IS NOT NULL THEN 1 END",
                  w.state,
                  w.last_error
                )
              )
          }
        )
      ) || %{ready: 0, starting: 0, unhealthy: 0}

    running_jobs =
      Repo.one(
        from(j in BackgroundJob,
          join: t in Tenant,
          on: t.id == j.tenant_id and is_nil(t.deleting_at),
          where: j.status in [:queued, :running, :waiting_on_user],
          select: count(j.id)
        )
      ) || 0

    %{
      active_tenants: tenant_counts.active,
      suspended_tenants: tenant_counts.suspended,
      active_agents: agent_counts.active,
      disabled_agents: agent_counts.disabled,
      ready_workers: worker_counts.ready,
      starting_workers: worker_counts.starting,
      unhealthy_workers: worker_counts.unhealthy,
      running_background_jobs: running_jobs
    }
  end

  defp dispatch(:agents, args) do
    from(a in Agent,
      join: t in Tenant,
      on: t.id == a.tenant_id and is_nil(t.deleting_at),
      join: p in Principal,
      on: p.tenant_id == a.tenant_id and p.uid == a.uid,
      left_join: w in AgentWorker,
      on: w.tenant_id == a.tenant_id and w.agent_uid == a.uid,
      order_by: [asc: t.slug, asc: a.uid],
      select: %{
        tenant_id: t.id,
        tenant_slug: t.slug,
        tenant_display_name: t.display_name,
        uid: a.uid,
        display_name: p.display_name,
        type: type(a.type, :string),
        status: type(p.status, :string),
        role: a.role,
        owner_principal_uid: a.owner_principal_uid,
        worker_provider_id: w.provider_id,
        worker_state: type(w.state, :string)
      }
    )
    |> maybe_search(args[:q], fn q, pat ->
      where(
        q,
        [a, t, p],
        ilike(a.uid, ^pat) or ilike(p.display_name, ^pat) or ilike(t.slug, ^pat) or
          ilike(t.display_name, ^pat)
      )
    end)
    |> maybe_status(args[:status], fn q, s ->
      where(q, [_a, _t, p], fragment("?::text = ?", p.status, ^s))
    end)
    |> apply_tuple_cursor(args[:cursor], 2, fn q, [slug, uid] ->
      where(q, [a, t], fragment("(?, ?) > (?, ?)", t.slug, a.uid, ^slug, ^uid))
    end)
    |> fetch_page(args.limit, &[&1.tenant_slug, &1.uid])
  end

  defp dispatch(:workers, args) do
    from(w in AgentWorker,
      join: t in Tenant,
      on: t.id == w.tenant_id and is_nil(t.deleting_at),
      order_by: [asc: t.slug, asc: w.agent_uid],
      select: %{
        tenant_id: t.id,
        tenant_slug: t.slug,
        tenant_display_name: t.display_name,
        agent_uid: w.agent_uid,
        provider_id: w.provider_id,
        state: type(w.state, :string),
        generation: w.generation,
        image: w.image,
        capacity: w.capacity,
        load: w.load,
        last_worker_heartbeat_at: w.last_worker_heartbeat_at,
        state_changed_at: w.state_changed_at,
        drain_reason: w.drain_reason,
        last_error: w.last_error
      }
    )
    |> maybe_search(args[:q], fn q, pat ->
      where(
        q,
        [w, t],
        ilike(w.agent_uid, ^pat) or ilike(w.provider_id, ^pat) or ilike(t.slug, ^pat) or
          ilike(t.display_name, ^pat)
      )
    end)
    |> maybe_status(args[:status], fn q, s ->
      where(q, [w], fragment("?::text = ?", w.state, ^s))
    end)
    |> apply_tuple_cursor(args[:cursor], 2, fn q, [slug, uid] ->
      where(q, [w, t], fragment("(?, ?) > (?, ?)", t.slug, w.agent_uid, ^slug, ^uid))
    end)
    |> fetch_page(args.limit, &[&1.tenant_slug, &1.agent_uid], fn row ->
      %{
        row
        | last_worker_heartbeat_at: iso(row.last_worker_heartbeat_at),
          state_changed_at: iso(row.state_changed_at) || ""
      }
    end)
  end

  defp dispatch(:principals, args) do
    base =
      from(p in Principal,
        join: t in Tenant,
        on: t.id == p.tenant_id and is_nil(t.deleting_at),
        left_join: h in HumanUser,
        on: h.tenant_id == p.tenant_id and h.principal_uid == p.uid,
        left_join: s in ServiceAccount,
        on: s.tenant_id == p.tenant_id and s.uid == p.uid,
        order_by: [asc: t.slug, asc: p.uid],
        select: %{
          tenant_id: t.id,
          tenant_slug: t.slug,
          tenant_display_name: t.display_name,
          uid: p.uid,
          type: type(p.type, :string),
          status: type(p.status, :string),
          membership: type(p.membership, :string),
          display_name: p.display_name,
          email: h.email,
          service_kind: type(s.kind, :string)
        }
      )

    base =
      if args[:include_disabled] == true, do: base, else: where(base, [p], p.status == :active)

    base = if args[:include_system] == true, do: base, else: where(base, [p], p.type != :system)

    base
    |> maybe_search(args[:q], fn q, pat ->
      where(
        q,
        [p, t, h],
        ilike(p.uid, ^pat) or ilike(p.display_name, ^pat) or ilike(h.email, ^pat) or
          ilike(t.slug, ^pat) or ilike(t.display_name, ^pat)
      )
    end)
    |> apply_tuple_cursor(args[:cursor], 2, fn q, [slug, uid] ->
      where(q, [p, t], fragment("(?, ?) > (?, ?)", t.slug, p.uid, ^slug, ^uid))
    end)
    |> fetch_page(args.limit, &[&1.tenant_slug, &1.uid])
  end

  defp dispatch(:signal_bindings, args) do
    base =
      from(b in Binding,
        join: t in Tenant,
        on: t.id == b.tenant_id and is_nil(t.deleting_at),
        order_by: [asc: t.slug, asc: b.name, asc: b.id],
        select: %{
          tenant_id: t.id,
          tenant_slug: t.slug,
          tenant_display_name: t.display_name,
          id: b.id,
          name: b.name,
          adapter: b.adapter,
          routing_mode: type(b.routing_mode, :string),
          agent_uid: b.agent_uid,
          enabled: b.enabled,
          external_bot_policy: type(b.external_bot_policy, :string),
          unavailable_reason: b.unavailable_reason
        }
      )

    base = if args[:include_disabled] == true, do: base, else: where(base, [b], b.enabled == true)

    base
    |> maybe_search(args[:q], fn q, pat ->
      where(
        q,
        [b, t],
        ilike(b.name, ^pat) or ilike(b.adapter, ^pat) or ilike(b.agent_uid, ^pat) or
          ilike(t.slug, ^pat) or ilike(t.display_name, ^pat)
      )
    end)
    |> apply_tuple_cursor(args[:cursor], 3, fn q, [slug, name, id_str] ->
      case Ecto.UUID.dump(id_str) do
        {:ok, id_bin} ->
          where(
            q,
            [b, t],
            fragment("(?, ?, ?) > (?, ?, ?)", t.slug, b.name, b.id, ^slug, ^name, ^id_bin)
          )

        :error ->
          q
      end
    end)
    |> fetch_page(args.limit, &[&1.tenant_slug, &1.name, &1.id])
  end

  defp dispatch(:schedules, args) do
    from(c in CronSchedule,
      join: t in Tenant,
      on: t.id == c.tenant_id and is_nil(t.deleting_at),
      where: c.status != :deleted and not is_nil(c.agent_uid),
      order_by: [asc: t.slug, asc: c.agent_uid, asc: c.name, asc: c.id],
      select: %{
        tenant_id: t.id,
        tenant_slug: t.slug,
        tenant_display_name: t.display_name,
        id: c.id,
        agent_uid: c.agent_uid,
        name: c.name,
        status: type(c.status, :string),
        timezone: c.timezone,
        next_fire_at: c.next_fire_at,
        last_fire_at: c.last_fire_at
      }
    )
    |> maybe_search(args[:q], fn q, pat ->
      where(
        q,
        [c, t],
        ilike(c.name, ^pat) or ilike(c.agent_uid, ^pat) or ilike(t.slug, ^pat) or
          ilike(t.display_name, ^pat)
      )
    end)
    |> maybe_status(args[:status], fn q, s ->
      where(q, [c], fragment("?::text = ?", c.status, ^s))
    end)
    |> apply_tuple_cursor(args[:cursor], 4, fn q, [slug, agent_uid, name, id_str] ->
      case Ecto.UUID.dump(id_str) do
        {:ok, id_bin} ->
          where(
            q,
            [c, t],
            fragment(
              "(?, ?, ?, ?) > (?, ?, ?, ?)",
              t.slug,
              c.agent_uid,
              c.name,
              c.id,
              ^slug,
              ^agent_uid,
              ^name,
              ^id_bin
            )
          )

        :error ->
          q
      end
    end)
    |> fetch_page(args.limit, &[&1.tenant_slug, &1.agent_uid, &1.name, &1.id], fn row ->
      %{row | next_fire_at: iso(row.next_fire_at), last_fire_at: iso(row.last_fire_at)}
    end)
  end

  defp dispatch(:background_agent_jobs, args) do
    base =
      from(j in BackgroundJob,
        join: t in Tenant,
        on: t.id == j.tenant_id and is_nil(t.deleting_at),
        order_by: [desc: j.id],
        select: %{
          tenant_id: t.id,
          tenant_slug: t.slug,
          tenant_display_name: t.display_name,
          id: j.id,
          agent_uid: j.agent_uid,
          title: j.title,
          status: type(j.status, :string),
          attempts: j.attempts,
          queued_at: j.queued_at,
          started_at: j.started_at,
          completed_at: j.completed_at
        }
      )
      |> maybe_search(args[:q], fn q, pat ->
        where(
          q,
          [j, t],
          ilike(j.title, ^pat) or ilike(j.agent_uid, ^pat) or ilike(t.slug, ^pat) or
            ilike(t.display_name, ^pat)
        )
      end)
      |> maybe_status(args[:status], fn q, s ->
        where(q, [j], fragment("?::text = ?", j.status, ^s))
      end)

    base =
      case decode_int_cursor(args[:cursor]) do
        {:ok, last_id} -> where(base, [j], j.id < ^last_id)
        :none -> base
      end

    fetch_page(
      base,
      args.limit,
      fn row -> Integer.to_string(row.id) end,
      fn row ->
        %{
          row
          | queued_at: iso(row.queued_at),
            started_at: iso(row.started_at),
            completed_at: iso(row.completed_at)
        }
      end
    )
  end

  defp dispatch(:ai_usage, %{days: days}) do
    since = DateTime.add(DateTime.utc_now(:microsecond), -days * 86_400, :second)

    totals =
      Repo.one(
        from(u in UsageRecord,
          join: t in Tenant,
          on: t.id == u.tenant_id and is_nil(t.deleting_at),
          where: u.capability == "llm" and u.inserted_at >= ^since,
          select: %{
            rounds: count(u.id),
            input_tokens: type(coalesce(sum(u.input_tokens), 0), :integer),
            output_tokens: type(coalesce(sum(u.output_tokens), 0), :integer)
          }
        )
      ) || %{rounds: 0, input_tokens: 0, output_tokens: 0}

    by_tenant =
      Repo.all(
        from(t in Tenant,
          where: is_nil(t.deleting_at),
          left_join: u in UsageRecord,
          on: u.tenant_id == t.id and u.capability == "llm" and u.inserted_at >= ^since,
          group_by: [t.id, t.slug, t.display_name],
          order_by: [desc: count(u.id), asc: t.slug],
          limit: 200,
          select: %{
            tenant_id: t.id,
            tenant_slug: t.slug,
            tenant_display_name: t.display_name,
            rounds: count(u.id),
            input_tokens: type(coalesce(sum(u.input_tokens), 0), :integer),
            output_tokens: type(coalesce(sum(u.output_tokens), 0), :integer),
            cached_input_tokens: type(coalesce(sum(u.cached_input_tokens), 0), :integer),
            reasoning_tokens: type(coalesce(sum(u.reasoning_tokens), 0), :integer)
          }
        )
      )

    %{
      window_started_at: DateTime.to_iso8601(since),
      total_rounds: totals.rounds,
      total_input_tokens: totals.input_tokens,
      total_output_tokens: totals.output_tokens,
      by_tenant: by_tenant
    }
  end

  defp fetch_page(query, limit, cursor_fn, row_mapper \\ &Function.identity/1) do
    rows = query |> limit(^(limit + 1)) |> Repo.all() |> Enum.map(row_mapper)
    {items, rest} = Enum.split(rows, limit)

    next_cursor =
      case {items, rest} do
        {[_ | _], [_ | _]} -> encode_cursor(cursor_fn.(List.last(items)))
        _ -> nil
      end

    %{items: items, next_cursor: next_cursor}
  end

  defp encode_cursor(raw) when is_binary(raw), do: Base.url_encode64(raw, padding: false)

  defp encode_cursor(tuple_list) when is_list(tuple_list),
    do: Base.url_encode64(Ankole.JSON.encode!(tuple_list), padding: false)

  defp maybe_search(query, raw_q, filter_fn) do
    case like_pattern(raw_q) do
      nil -> query
      pat -> filter_fn.(query, pat)
    end
  end

  defp maybe_status(query, raw_status, filter_fn) do
    case trimmed(raw_status) do
      nil -> query
      status -> filter_fn.(query, status)
    end
  end

  defp apply_tuple_cursor(query, raw_cursor, arity, filter_fn) do
    with cursor when is_binary(cursor) and cursor != "" <- raw_cursor,
         {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, parts} when is_list(parts) and length(parts) == arity <-
           Ankole.JSON.decode(decoded),
         true <- Enum.all?(parts, &is_binary/1) do
      filter_fn.(query, parts)
    else
      _ -> query
    end
  end

  defp decode_int_cursor(raw_cursor) when is_binary(raw_cursor) and raw_cursor != "" do
    with {:ok, decoded} <- Base.url_decode64(raw_cursor, padding: false),
         {id, ""} <- Integer.parse(decoded) do
      {:ok, id}
    else
      _ -> :none
    end
  end

  defp decode_int_cursor(_), do: :none

  defp trimmed(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      s -> s
    end
  end

  defp trimmed(_), do: nil

  defp like_pattern(val) do
    case trimmed(val) do
      nil ->
        nil

      s ->
        escaped =
          s
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")

        "%#{escaped}%"
    end
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
  defp iso(_), do: nil
end
