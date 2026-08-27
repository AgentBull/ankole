defmodule Ankole.SignalsGateway.IdentityAdmission do
  @moduledoc """
  Maps inbound entry authors to Principals and applies the binding's
  unmatched-sender policy.

  Identification is best effort and always automatic: an existing
  platform-subject binding for any candidate id wins, then the owner of the
  platform-reported email or mobile number. What an unmatched sender means is
  the binding's `unmatched_sender_policy`: `:create_standalone` creates a
  standalone account and serves them; `:manual_review` records the sender in
  the console pending list, answers an addressed message with one fixed
  notice, and gives the sender no other processing at all — no mirror, no
  inbound batch.

  Admitted senders accumulate into one `signal_source` AuthZ group per binding
  so permission policy can address "users of this signal source".
  """

  alias Ankole.AuthZ
  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.FactNormalizer
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Projection

  @doc """
  Admits the author of one normalized entry fact.

  Returns `{:ok, fact}` with the author resolved to a Principal, or
  `{:held, result}` when the fact must not be processed: the sender waits for
  manual review, or the sender's Principal is disabled. The held result is the
  ingress status map.
  """
  @spec admit_entry(Binding.t(), IngressFact.t(), DateTime.t()) ::
          {:ok, IngressFact.t()} | {:held, map()}
  def admit_entry(%Binding{} = binding, fact, now) do
    author = fact.author || %{}

    cond do
      is_binary(author["principal_uid"]) ->
        {:ok, fact}

      subject_candidates(author) == [] ->
        {:ok, fact}

      true ->
        resolve_subject(binding, fact, now)
    end
  end

  defp resolve_subject(%Binding{} = binding, fact, now) do
    author = fact.author

    case subject_provider(binding, author) do
      {:ok, provider} ->
        case Principals.match_platform_subject_human(match_attrs(provider, author)) do
          {:ok, principal} ->
            {:ok, admit(binding, fact, provider, author, principal.uid)}

          {:error, :not_found} ->
            handle_unmatched(binding, fact, provider, now)

          {:error, reason} ->
            held_silently(fact, reason)
        end

      {:error, reason} ->
        held_silently(fact, reason)
    end
  end

  defp handle_unmatched(%Binding{} = binding, fact, provider, now) do
    author = maybe_hydrate_author(binding, fact)

    rematch =
      case hydrated_contacts?(author, fact.author) do
        true -> Principals.match_platform_subject_human(match_attrs(provider, author))
        false -> {:error, :not_found}
      end

    case rematch do
      {:ok, principal} ->
        {:ok, admit(binding, %{fact | author: author}, provider, author, principal.uid)}

      {:error, :not_found} ->
        apply_policy(binding, %{fact | author: author}, provider, now)

      {:error, reason} ->
        held_silently(fact, reason)
    end
  end

  defp apply_policy(
         %Binding{unmatched_sender_policy: :create_standalone} = binding,
         fact,
         provider,
         _now
       ) do
    case upsert_subject(provider, fact.author, nil) do
      {:ok, principal} ->
        {:ok, admitted_fact(binding, put_author_display(fact, principal), principal.uid)}

      {:error, reason} ->
        held_silently(fact, {:standalone_account_failed, reason})
    end
  end

  defp apply_policy(%Binding{unmatched_sender_policy: :manual_review}, fact, provider, now) do
    case IngressFact.addressed_im_entry?(fact) do
      true ->
        record_mapping_request(fact, provider)
        notify_held_sender(fact, now)
        {:held, %{status: :held_unmapped_sender}}

      false ->
        {:held, %{status: :ignored_unmapped_sender}}
    end
  end

  # A match hit still writes: the primary subject id gets or refreshes its
  # identity binding and contact fields. The platform display name only fills
  # a blank profile; an observation never renames a known person — only
  # directory sync carries an authoritative name.
  defp admit(%Binding{} = binding, fact, provider, author, principal_uid) do
    case upsert_subject(provider, author, principal_uid) do
      {:ok, principal} ->
        admitted_fact(binding, put_author_display(fact, principal), principal.uid)

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.identity_admission.subject_upsert_failed",
          "admitted sender identity refresh failed",
          %{binding: fact.binding_name, reason: inspect(reason)}
        )

        admitted_fact(binding, fact, principal_uid)
    end
  end

  defp admitted_fact(%Binding{} = binding, fact, principal_uid) do
    ensure_signal_source_membership(binding, principal_uid)
    FactNormalizer.put_author_principal(fact, principal_uid)
  end

  # Absent attributes must stay absent: a nil display name or contact here
  # would erase the value directory sync already wrote to the profile.
  defp upsert_subject(provider, author, principal_uid) do
    attrs =
      %{
        provider: provider,
        external_id: primary_subject(author),
        metadata: subject_metadata(author)
      }
      |> Ankole.Attrs.maybe_put(:display_name, author["display_name"])
      |> Ankole.Attrs.maybe_put(:email, author["email"])
      |> Ankole.Attrs.maybe_put(:mobile, author["mobile"])
      |> Ankole.Attrs.maybe_put(:uid, principal_uid)

    case Principals.upsert_platform_subject_human(attrs) do
      {:ok, %{principal: principal}} -> {:ok, principal}
      {:error, _reason} = error -> error
    end
  end

  # The Principal display name is the authoritative human name (directory or
  # console managed), so it wins over the provider sender label on the fact.
  defp put_author_display(fact, %{display_name: display_name})
       when is_binary(display_name) and display_name != "" do
    %{fact | author: Map.put(fact.author, "display_name", display_name)}
  end

  defp put_author_display(fact, _principal), do: fact

  defp held_silently(fact, reason) do
    Logging.warning(
      "signals_gateway.identity_admission.sender_refused",
      "inbound sender refused without admission",
      %{
        binding: fact.binding_name,
        agent_uid: fact.agent_uid,
        signal_channel_id: fact.signal_channel_id,
        reason: inspect(reason)
      }
    )

    {:held, %{status: :ignored_unmapped_sender}}
  end

  defp record_mapping_request(fact, provider) do
    author = fact.author

    attrs = %{
      provider: provider,
      external_id: primary_subject(author),
      display_name: author["display_name"],
      email: author["email"],
      mobile: author["mobile"],
      metadata:
        %{
          "alternate_external_ids" => subject_alternates(author),
          "agent_uid" => fact.agent_uid,
          "binding_name" => fact.binding_name,
          "adapter" => fact.adapter,
          "channel_name" => fact.channel_name,
          "author_metadata" => author["metadata"] || %{}
        }
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
        |> Map.new()
    }

    case MappingRequests.record_observation(attrs) do
      {:ok, _request} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.identity_admission.mapping_request_failed",
          "unmapped sender observation could not be recorded",
          %{binding: fact.binding_name, reason: inspect(reason)}
        )

        :ok
    end
  end

  # The notice needs a channel mirror row to route the reply; the held entry
  # itself is never mirrored.
  defp notify_held_sender(fact, now) do
    result =
      Repo.transact(fn repo ->
        with {:ok, _channel} <- Projection.upsert_channel(repo, fact, now),
             {:ok, outbox} <- Outbox.commit_outbox_in_tx(repo, held_notice_attrs(fact)) do
          {:ok, outbox}
        end
      end)

    case result do
      {:ok, _outbox} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.identity_admission.notice_failed",
          "unmapped sender notice could not be committed",
          %{binding: fact.binding_name, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp held_notice_attrs(fact) do
    outbound_key = "unmapped_sender:#{fact.signal_channel_id}:#{fact.source_entry_id}"

    %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      outbound_key: outbound_key,
      operation: :reply,
      delivery_class: :generic,
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: fact.provider_thread_id,
      reply_to_source_entry_id: fact.source_entry_id,
      payload: %{"metadata" => %{"source" => "unmapped_sender_notice"}},
      fallback_visible_text: I18n.t("signals_gateway.reply.unmapped_sender"),
      idempotency_key: outbound_key
    }
  end

  defp maybe_hydrate_author(%Binding{} = binding, fact) do
    author = fact.author

    with true <- hydration_wanted?(binding, fact),
         true <- author["email"] == nil or author["mobile"] == nil,
         {:ok, %Adapters.Definition{author_hydrator: module}} when not is_nil(module) <-
           Adapters.fetch(binding.adapter),
         {:ok, config} <- Bindings.stored_binding_config(binding),
         {:ok, extra} when is_map(extra) <- safe_hydrate(module, config, author) do
      author
      |> put_missing("email", extra["email"])
      |> put_missing("mobile", extra["mobile"])
      |> put_missing("display_name", extra["display_name"])
    else
      _no_hydration -> author
    end
  end

  # Hydration costs one provider API call, so it runs only when the result can
  # matter right now: the sender addressed the agent, or the binding would
  # create a standalone account that a contact match should prevent.
  defp hydration_wanted?(%Binding{unmatched_sender_policy: :create_standalone}, _fact), do: true
  defp hydration_wanted?(%Binding{}, fact), do: IngressFact.addressed_im_entry?(fact)

  defp safe_hydrate(module, config, author) do
    module.hydrate_author(config, author)
  catch
    kind, reason ->
      Logging.warning(
        "signals_gateway.identity_admission.hydration_failed",
        "author hydration raised",
        %{module: inspect(module), reason: inspect({kind, reason})}
      )

      {:error, {kind, reason}}
  end

  defp hydrated_contacts?(hydrated, original) do
    (hydrated["email"] != nil and original["email"] == nil) or
      (hydrated["mobile"] != nil and original["mobile"] == nil)
  end

  defp match_attrs(provider, author) do
    %{
      provider: provider,
      external_ids: subject_candidates(author),
      email: author["email"],
      mobile: author["mobile"]
    }
  end

  defp subject_provider(%Binding{} = binding, author) do
    provider =
      text(author["provider"]) ||
        text(get_in(author, ["metadata", "provider"])) ||
        binding.name

    case Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, provider) do
      true -> {:ok, provider}
      false -> {:error, {:invalid_subject_provider, provider}}
    end
  end

  defp primary_subject(author), do: author |> subject_candidates() |> List.first()

  defp subject_alternates(author), do: author |> subject_candidates() |> Enum.drop(1)

  defp subject_candidates(author) when is_map(author) do
    alternates =
      case author["platform_subject_alternates"] do
        list when is_list(list) -> list
        _other -> []
      end

    [author["platform_subject"] | alternates]
    |> Enum.map(&text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp subject_candidates(_author), do: []

  defp subject_metadata(author) do
    metadata =
      case author["metadata"] do
        metadata when is_map(metadata) -> metadata
        _other -> %{}
      end

    case subject_alternates(author) do
      [] -> metadata
      alternates -> Map.put(metadata, "alternate_external_ids", alternates)
    end
  end

  defp ensure_signal_source_membership(%Binding{} = binding, principal_uid) do
    group_attrs = %{
      name: signal_source_group_name(binding),
      display_name: "#{binding.name} @ #{binding.agent_uid}",
      domain: :signal_source,
      metadata: %{
        "signals_gateway" => %{
          "agent_uid" => binding.agent_uid,
          "binding_name" => binding.name
        }
      }
    }

    case AuthZ.ensure_synced_group_member(group_attrs, principal_uid) do
      :ok ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "signals_gateway.identity_admission.source_group_failed",
          "signal source group membership could not be ensured",
          %{
            binding: binding.name,
            agent_uid: binding.agent_uid,
            principal_uid: principal_uid,
            reason: inspect(reason)
          }
        )

        :ok
    end
  end

  @doc """
  Returns the AuthZ group name that accumulates a binding's admitted senders.
  """
  @spec signal_source_group_name(Binding.t()) :: String.t()
  def signal_source_group_name(%Binding{} = binding) do
    String.downcase("signal_source:#{binding.agent_uid}:#{binding.name}")
  end

  defp put_missing(map, _key, nil), do: map

  defp put_missing(map, key, value) do
    case map[key] do
      nil -> Map.put(map, key, value)
      _present -> map
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil
end
