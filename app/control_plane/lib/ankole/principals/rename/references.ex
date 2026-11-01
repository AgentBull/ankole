defmodule Ankole.Principals.Rename.References do
  @moduledoc """
  The identity copies that cannot follow a Principal foreign key.

  A rename matches local names in their row's tenant and ActorRefs by their
  full tenant-qualified value, including attribution stored by another tenant.
  JSON paths name identity fields explicitly; credentials and arbitrary user
  payloads are not identity copies.
  """
  alias Ankole.Repo

  @principal_keys [
    {"authn_challenges", "principal_uid"},
    {"automation_jobs", "human_uid"},
    {"background_agent_jobs", "human_uid"},
    {"browser_oidc_states", "reauthentication_principal_uid"},
    {"browser_pod_authentications", "principal_uid"},
    {"conversation_action_cards", "agent_uid"},
    {"conversation_action_cards", "resolved_by_uid"},
    {"conversation_inbound_batches", "requester_sender_key"},
    {"cron_schedules", "human_uid"},
    {"delivery_attachments", "agent_uid"},
    {"human_access_events", "principal_uid"},
    {"human_access_restrictions", "principal_uid"},
    {"oidc_sessions", "principal_uid"},
    {"page_user_states", "principal_uid"},
    {"principal_site_credentials", "principal_uid"},
    {"scheduled_events", "human_uid"},
    {"signals", "human_uid"},
    {"signals", "sender_key"},
    {"workflow_runs", "human_uid"}
  ]
  @principal_key_arrays [
    {"identity_directory_states", "member_uids"},
    {"identity_directory_states", "missing_uids"}
  ]
  @actor_refs [
    {"agent_skill_lessons", "author"},
    {"agents", "created_by"},
    {"brain_claims", "author"},
    {"brain_claims", "resolved_by"},
    {"brain_merge_suggestions", "decided_by"},
    {"brain_object_versions", "author"},
    {"brain_schema_suggestions", "decided_by"},
    {"brain_timelines", "author"},
    {"drive_nodes", "created_by"},
    {"human_access_events", "actor"},
    {"identity_directory_events", "reviewed_by"},
    {"identity_directory_states", "reviewed_by"},
    {"page_changes", "author"},
    {"page_comments", "activity_by"},
    {"page_comments", "author"},
    {"page_comments", "deleted_by"},
    {"page_comments", "resolved_by"},
    {"page_comments", "updated_by"},
    {"page_contents", "updated_by"},
    {"page_snapshots", "author"}
  ]
  @actor_ref_arrays [{"page_contents", "contributors"}]
  @json_uids [
    {"conversations", "metadata", ["dm_peer_principal_uid"]},
    {"identity_mapping_requests", "metadata", ["agent_uid"]},
    {"external_message_refs", "author", ["principal_uid"]},
    {"external_message_refs", "author", ["agent_uid"]},
    {"principal_groups", "metadata", ["signals", "agent_uid"]},
    {"conversation_messages", "rich_content", ["target_agent_uid"]},
    {"conversation_messages", "rich_content", ["event", "actor_uid"]},
    {"signals", "data", ["author_uid"]},
    {"signals", "data", ["session", "agent_uid"]},
    {"signals", "data", ["entry", "author", "principal_uid"]},
    {"signals", "data", ["entry", "author", "agent_uid"]},
    {"signals", "data", ["entry", "reply_to", "author", "principal_uid"]},
    {"signals", "data", ["entry", "reply_to", "author", "agent_uid"]}
  ]
  @json_actor_refs [{"cron_schedules", "created_by", ["principal_uid"]}]
  # :each visits only the declared collection. Provider subjects, raw payloads,
  # free text and arbitrary task inputs retain their original meaning.
  @json_collections [
    {"principal_groups", "metadata", :jsonb,
     [["signals", "binding_memberships", :each, "agent_uid"]]},
    {"conversation_messages", "mentions", :array, [[:each, "uid"]]},
    {"conversation_messages", "rich_content", :jsonb, [["event", "targets", :each, "uid"]]},
    {"conversation_action_cards", "payload", :jsonb,
     [["participant_uids", :each], ["grants", :each, "principal_uid"]]},
    {"conversation_action_cards", "notified_senders", :jsonb, [[:each]]},
    {"conversation_inbound_batches", "entries", :jsonb,
     [
       [:each, "agent_uid"],
       [:each, "sender_key"],
       [:each, "author", "principal_uid"],
       [:each, "author", "agent_uid"],
       [:each, "reply_to", "author", "principal_uid"],
       [:each, "reply_to", "author", "agent_uid"]
     ]},
    {"signals", "data", :jsonb,
     [
       ["native_edit_mentions", :each, "uid"],
       ["entries", :each, "agent_uid"],
       ["entries", :each, "sender_key"],
       ["entries", :each, "author", "principal_uid"],
       ["entries", :each, "author", "agent_uid"],
       ["entries", :each, "reply_to", "author", "principal_uid"],
       ["entries", :each, "reply_to", "author", "agent_uid"]
     ]}
  ]

  @doc false
  def registered_columns do
    %{
      principal_key: @principal_keys,
      principal_keys: @principal_key_arrays,
      actor_ref: @actor_refs,
      actor_refs: @actor_ref_arrays
    }
  end

  def rewrite_in_tx(old_uid, new_uid, principal_type) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :rewrite_in_tx}
        )

    tenant_id = Repo.tenant_id!()

    Enum.each(@principal_keys, &rewrite_scalar(&1, tenant_id, old_uid, new_uid))
    Enum.each(@principal_key_arrays, &rewrite_array(&1, tenant_id, old_uid, new_uid))
    Enum.each(@json_uids, &rewrite_json_scalar(&1, tenant_id, old_uid, new_uid))
    Enum.each(@json_collections, &rewrite_json_collection(&1, tenant_id, old_uid, new_uid))

    # ActorRefs contain the owning tenant themselves. An administrator's
    # attribution in another tenant follows the same renamed identity.
    Repo.across_tenants(fn ->
      Enum.each(@actor_refs, &rewrite_actor(&1, tenant_id, old_uid, new_uid))
      Enum.each(@actor_ref_arrays, &rewrite_actor_array(&1, tenant_id, old_uid, new_uid))
      Enum.each(@json_actor_refs, &rewrite_json_actor(&1, tenant_id, old_uid, new_uid))
    end)

    rename_browser_subject(tenant_id, old_uid, new_uid)
    rename_pending_jobs(tenant_id, old_uid, new_uid)
    rename_conversation_keys(tenant_id, old_uid, new_uid)
    rename_resources(tenant_id, old_uid, new_uid)
    rename_brain(tenant_id, old_uid, new_uid, principal_type)
    :ok
  end

  defp rename_resources(tenant_id, old_uid, new_uid) do
    for prefix <- [
          "agent:",
          "drive:private:",
          "site_console:agent:",
          "tenant_console:agent:",
          "site_console:principal:",
          "tenant_console:principal:"
        ] do
      old = prefix <> old_uid
      new = prefix <> new_uid

      Repo.query!(
        "UPDATE permission_grants SET resource_pattern=$3 || substring(resource_pattern FROM length($2)+1) WHERE tenant_id=$1::text::uuid AND (resource_pattern=$2 OR left(resource_pattern,length($2)+1)=$2 || ':')",
        [tenant_id, old, new]
      )
    end
  end

  defp rename_brain(tenant_id, old_uid, new_uid, principal_type) do
    old_slug = Ankole.Brain.principal_page_slug(principal_type, old_uid)
    new_slug = Ankole.Brain.principal_page_slug(principal_type, new_uid)

    for {table, column} <- [
          {"brain_objects", "slug"},
          {"brain_slug_aliases", "alias_slug"},
          {"brain_merge_suggestions", "a_slug"},
          {"brain_merge_suggestions", "b_slug"}
        ] do
      rewrite_scalar({table, column}, tenant_id, old_slug, new_slug)
    end

    for {table, column} <- [
          {"brain_claims", "audience_scope"},
          {"brain_chunks", "audience_scope"},
          {"brain_timelines", "audience_scope"},
          {"brain_sources", "default_audience_scope"}
        ] do
      rewrite_scalar({table, column}, tenant_id, "principal:" <> old_uid, "principal:" <> new_uid)
    end
  end

  defp rewrite_scalar({table, column}, tenant_id, old, new) do
    Repo.query!(
      "UPDATE #{table} SET #{column}=$3 WHERE tenant_id=$1::text::uuid AND #{column}=$2",
      [tenant_id, old, new]
    )
  end

  defp rewrite_array({table, column}, tenant_id, old, new) do
    Repo.query!(
      "UPDATE #{table} SET #{column}=array_replace(#{column},$2,$3) WHERE tenant_id=$1::text::uuid AND $2=ANY(#{column})",
      [tenant_id, old, new]
    )
  end

  defp rewrite_actor({table, column}, tenant_id, old, new) do
    Repo.query!(
      """
      WITH identity AS (SELECT $1::text AS tenant_id)
      UPDATE #{table} SET #{column}='ankole:' || identity.tenant_id || ':principal/' || $3::text
      FROM identity
      WHERE #{column}='ankole:' || identity.tenant_id || ':principal/' || $2::text
      """,
      [tenant_id, old, new]
    )
  end

  defp rewrite_actor_array({table, column}, tenant_id, old, new) do
    Repo.query!(
      """
      WITH identity AS (SELECT $1::text AS tenant_id)
      UPDATE #{table} SET #{column}=array_replace(#{column},
        'ankole:' || identity.tenant_id || ':principal/' || $2::text,
        'ankole:' || identity.tenant_id || ':principal/' || $3::text)
      FROM identity
      WHERE ('ankole:' || identity.tenant_id || ':principal/' || $2::text)=ANY(#{column})
      """,
      [tenant_id, old, new]
    )
  end

  defp rewrite_json_scalar({table, column, path}, tenant_id, old, new) do
    Repo.query!(
      "UPDATE #{table} SET #{column}=jsonb_set(#{column},$2::text[],to_jsonb($4::text),false) WHERE tenant_id=$1::text::uuid AND #{column} #>> $2::text[] = $3",
      [tenant_id, path, old, new]
    )
  end

  defp rewrite_json_actor({table, column, path}, tenant_id, old, new) do
    Repo.query!(
      """
      WITH identity AS (SELECT $1::text AS tenant_id)
      UPDATE #{table} SET #{column}=jsonb_set(#{column},$4::text[],
        to_jsonb('ankole:' || identity.tenant_id || ':principal/' || $3::text),false)
      FROM identity
      WHERE #{column} #>> $4::text[]='ankole:' || identity.tenant_id || ':principal/' || $2::text
      """,
      [tenant_id, old, new, path]
    )
  end

  defp rewrite_json_collection({table, column, storage, paths}, tenant_id, old, new) do
    rows =
      Repo.query!(
        "SELECT to_jsonb(#{column}) FROM #{table} WHERE tenant_id=$1::text::uuid AND strpos(to_jsonb(#{column})::text,$2)>0 FOR UPDATE",
        [tenant_id, Ankole.JSON.encode!(old)]
      ).rows

    assignment =
      if storage == :array, do: "ARRAY(SELECT jsonb_array_elements($3::jsonb))", else: "$3::jsonb"

    Enum.each(rows, fn [before] ->
      updated = Enum.reduce(paths, before, &replace_path(&2, &1, old, new))

      if updated != before do
        Repo.query!(
          "UPDATE #{table} SET #{column}=#{assignment} WHERE tenant_id=$1::text::uuid AND to_jsonb(#{column})=$2::jsonb",
          [tenant_id, before, updated]
        )
      end
    end)
  end

  defp replace_path(old, [], old, new), do: new

  defp replace_path(values, [:each | path], old, new) when is_list(values),
    do: Enum.map(values, &replace_path(&1, path, old, new))

  defp replace_path(values, [:each | path], old, new) when is_map(values),
    do: Map.new(values, fn {key, value} -> {key, replace_path(value, path, old, new)} end)

  defp replace_path(values, [key | path], old, new) when is_map(values) do
    case Map.fetch(values, key) do
      {:ok, value} -> Map.put(values, key, replace_path(value, path, old, new))
      :error -> values
    end
  end

  defp replace_path(value, _path, _old, _new), do: value

  defp rename_browser_subject(tenant_id, old, new) do
    Repo.query!(
      "UPDATE browser_authentications SET subject_id=$3 WHERE tenant_id=$1::text::uuid AND scope='tenant' AND subject_id=$2",
      [tenant_id, old, new]
    )
  end

  defp rename_pending_jobs(tenant_id, old, new) do
    for key <- ~w(agent_uid human_uid principal_uid) do
      Repo.query!(
        "UPDATE oban_jobs SET args=jsonb_set(args,ARRAY[$2::text],to_jsonb($4::text),false) WHERE args->>'tenant_id'=$1 AND args->>$2=$3 AND state IN ('available','scheduled','retryable','executing')",
        [tenant_id, key, old, new]
      )
    end
  end

  defp rename_conversation_keys(tenant_id, old, new) do
    for {column, prefix} <- [
          {"preferred_models", ""},
          {"metadata", "queue_paused:"},
          {"metadata", "queue_pause_command_id:"}
        ] do
      Repo.query!(
        "UPDATE conversations SET #{column}=(#{column} - $2) || jsonb_build_object($3::text,#{column}->$2) WHERE tenant_id=$1::text::uuid AND #{column} ? $2",
        [tenant_id, prefix <> old, prefix <> new]
      )
    end
  end
end
