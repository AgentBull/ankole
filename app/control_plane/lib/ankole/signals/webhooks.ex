defmodule Ankole.Signals.Webhooks do
  @moduledoc """
  Owns webhook capability URLs and their durable consumer handoff.

  A capability URL authorizes one delivery only. It does not authenticate the
  facts in the request body. An Agent or bound automation job must verify those
  facts through the external system before it makes a consequential change.
  """

  require Ash.Query

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationJobRun
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Signals.WebhookEndpoint

  @active_statuses [:armed, :active]
  @token_pattern ~r/\Awh_[A-Za-z0-9_-]{43}\z/

  @type receive_result ::
          {:ok,
           %{
             optional(:signal) => Ankole.Signals.Signal.t(),
             optional(:automation_job_run) => AutomationJobRun.t(),
             status: :accepted | :ignored,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}

  @doc """
  Generates a capability for one new endpoint and stores only its token digest.

  The returned plaintext token is used once to construct the callback URL.
  """
  @spec create_endpoint(map(), keyword()) ::
          {:ok, %{webhook_endpoint: WebhookEndpoint.t(), token: String.t()}} | {:error, term()}
  def create_endpoint(attrs, opts \\ [])

  def create_endpoint(attrs, opts) when is_map(attrs) do
    with {:ok, attrs, token} <- prepare_endpoint(attrs, opts) do
      Repo.transact_top_level(fn -> create_endpoint_in_tx(attrs, token) end)
    end
  end

  def create_endpoint(_attrs, _opts), do: {:error, :invalid_webhook_endpoint}

  @doc "Returns one WebhookEndpoint by ID, or nil."
  def get_endpoint(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> WebhookEndpoint |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()
      :error -> nil
    end
  end

  def get_endpoint(_id), do: nil

  @doc false
  # The Console creates a standing CloudEvents endpoint for an operator.
  def create_operator_endpoint_in_tx(%{label: label, expires_at: expires_at}) do
    with {:ok, attrs, token} <-
           prepare_endpoint(
             %{
               label: label,
               expires_at: expires_at,
               mode: "standing",
               event_format: "cloudevents",
               source_provenance: %{"kind" => "operator_api"}
             },
             []
           ) do
      create_endpoint_in_tx(attrs, token)
    end
  end

  def prepare_endpoint(attrs, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    token = "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, attrs} <- create_attrs(attrs, token),
         :ok <- validate_public_target(attrs),
         :ok <- validate_expiry(attrs, now) do
      {:ok, attrs, token}
    end
  end

  @doc false
  def create_endpoint_in_tx(attrs, token) do
    with :ok <-
           authorize_consumer(attrs),
         {:ok, endpoint} <-
           Ankole.Ash.create(WebhookEndpoint, :create, Map.delete(attrs, "automation_job_id")),
         :ok <- default_binding(endpoint, attrs["automation_job_id"]) do
      {:ok, %{webhook_endpoint: endpoint, token: token}}
    end
  end

  defp authorize_consumer(%{"owner_job_id" => id}) when is_integer(id), do: :ok

  defp authorize_consumer(attrs),
    do: AutomationJobs.authorize_bindable_in_tx(attrs["agent_uid"], attrs["automation_job_id"])

  def stop_human_work_in_tx(uid, version, _now) do
    {:ok, endpoints} =
      WebhookEndpoint
      |> Ash.Query.filter(
        human_uid == ^uid and human_access_version < ^version and status in [:armed, :active]
      )
      |> Ankole.Ash.update_where(:stop_human_work)

    {length(endpoints), endpoints}
  end

  @doc """
  Lists webhook endpoints for one Agent session, for every session of the
  Agent when `session_id` is `nil`, or across every Agent when `agent_uid` is
  also `nil`.

  Active-only lists exclude endpoints whose expiry time has already passed,
  even if the periodic sweep has not updated their stored status yet.
  """
  @spec list_endpoints(String.t() | nil, String.t() | nil, keyword()) :: [WebhookEndpoint.t()]
  def list_endpoints(agent_uid, session_id, opts \\ [])
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(session_id) or is_nil(session_id)) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit()

    WebhookEndpoint
    |> maybe_where_agent(agent_uid)
    |> maybe_where_session(session_id)
    |> maybe_active_only(Keyword.get(opts, :active_only, false), now)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  @doc """
  Cancels an active endpoint. Repeating the operation keeps the terminal state.

  A `nil` `session_id` accepts any session of the Agent.
  """
  @spec cancel_endpoint(String.t(), String.t() | nil, Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             status: :cancelled | :already_terminal,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}
  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts \\ [])

  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts)
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(session_id) or is_nil(session_id)) and
             is_binary(endpoint_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact_top_level(fn ->
      cancel_endpoint_in_tx(agent_uid, session_id, endpoint_id, now)
    end)
  end

  def cancel_endpoint(_agent_uid, _session_id, _endpoint_id, _opts),
    do: {:error, :webhook_endpoint_not_found}

  @doc false
  # The Console cancels an endpoint of any Agent and gives the endpoint.
  def cancel_operator_endpoint_in_tx(endpoint_id) do
    case cancel_endpoint_in_tx(nil, nil, endpoint_id, DateTime.utc_now(:microsecond)) do
      {:ok, %{webhook_endpoint: endpoint}} -> {:ok, endpoint}
      error -> Ankole.Errors.not_found(error, [:webhook_endpoint_not_found], WebhookEndpoint)
    end
  end

  @doc false
  def cancel_endpoint_in_tx(agent_uid, session_id, endpoint_id, now) do
    case lock_endpoint(endpoint_id, agent_uid && String.downcase(agent_uid), session_id) do
      %WebhookEndpoint{} = endpoint -> cancel_locked_endpoint(endpoint, now)
      nil -> {:error, :webhook_endpoint_not_found}
    end
  end

  @doc """
  Accepts one callback and stores its Signal or automation job run in the
  same transaction.
  """
  @spec receive(String.t(), [{String.t(), String.t()}], binary(), keyword()) :: receive_result()
  def receive(token, headers, body, opts \\ [])

  def receive(token, headers, body, opts)
      when is_binary(token) and is_list(headers) and is_binary(body) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    receive_at_endpoint(token, "raw", {:raw, headers, body}, now)
  end

  def receive(_token, _headers, _body, _opts), do: {:error, :webhook_endpoint_not_found}

  @doc "Receives a structured CloudEvent through an endpoint's own capability."
  def receive_cloudevent(token, event, opts \\ []) do
    receive_at_endpoint(
      token,
      "cloudevents",
      {:cloudevents, event},
      Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    )
  end

  defp receive_at_endpoint(token, format, input, now) do
    with :ok <- validate_token(token),
         %WebhookEndpoint{tenant_id: tenant_id, event_format: ^format} = endpoint <-
           endpoint_across_tenants(token) do
      Repo.with_tenant(tenant_id, fn ->
        if Ankole.Tenants.accepting_work?(tenant_id) do
          with {:ok, event} <- incoming_event(endpoint, input, now),
               do: receive_prepared(token, endpoint, event, now, 3)
        else
          {:ok, %{status: :ignored, webhook_endpoint: endpoint}}
        end
      end)
    else
      _ -> {:error, :webhook_endpoint_not_found}
    end
  end

  defp receive_prepared(token, endpoint, event, now, retries) do
    with {:ok, plan} <-
           Ankole.Signals.prepare_dispatch("webhook-endpoint://#{endpoint.id}", event,
             producer: :external,
             authorization: Ankole.Principals.WorkAccess.fields(endpoint),
             reply_route: reply_route(endpoint)
           ) do
      result =
        Repo.transact_top_level(
          fn ->
            with {:ok, plan} <- Ankole.Signals.lock_dispatch_in_tx(plan),
                 %WebhookEndpoint{event_format: format} = locked <- lock_endpoint_by_token(token),
                 true <- format == endpoint.event_format do
              receive_locked(locked, plan, now)
            else
              nil -> {:error, :webhook_endpoint_not_found}
              false -> {:error, :webhook_endpoint_not_found}
              error -> error
            end
          end,
          after_commit: fn result ->
            Ankole.Signals.publish_committed(Map.get(result, :signals))
          end
        )

      if result == {:error, :binding_changed} and retries > 0,
        do: receive_prepared(token, endpoint, event, now, retries - 1),
        else: result
    end
  end

  defp incoming_event(endpoint, {:raw, headers, body}, now),
    do:
      {:ok,
       receipt_payload(
         endpoint,
         "webhook:#{endpoint.id}:#{UUIDv7.autogenerate()}",
         headers,
         body,
         now
       )}

  defp incoming_event(_endpoint, {:cloudevents, event}, _now),
    do: Ankole.Signals.CloudEvents.normalize(event)

  defp default_binding(%{event_format: "cloudevents", owner_job_id: nil}, _), do: :ok

  defp default_binding(endpoint, job_id),
    do:
      Ankole.Signals.put_source_binding_in_tx(
        "webhook-endpoint://#{endpoint.id}",
        endpoint.agent_uid,
        endpoint.session_id,
        job_id
      )

  defp reply_route(endpoint),
    do: %{
      binding_name: endpoint.binding_name,
      conversation_id: endpoint.conversation_id,
      provider_thread_id: endpoint.provider_thread_id,
      provider_message_id: endpoint.provider_message_id
    }

  # The capability token selects the tenant before any tenant context exists.
  defp endpoint_across_tenants(token) do
    digest = token_digest(token)

    Repo.across_tenants(fn ->
      WebhookEndpoint
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(token_digest == ^digest)
      |> Ankole.Ash.read_one!()
    end)
  end

  # Keeps only callback headers that carry event metadata.
  #
  # Authentication and general HTTP headers are deliberately discarded.
  #
  @spec allowlisted_headers([{String.t(), String.t()}]) :: map()
  defp allowlisted_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn
      {name, value}, acc when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if allowlisted_header?(name) and durable_text?(value) do
          Map.update(acc, name, value, &(&1 <> ", " <> value))
        else
          acc
        end

      _header, acc ->
        acc
    end)
  end

  @doc """
  Marks due active endpoints as expired and returns the number changed.
  """
  @spec expire_due(DateTime.t()) :: non_neg_integer()
  def expire_due(%DateTime{} = now) do
    {:ok, expired} =
      WebhookEndpoint
      |> Ash.Query.filter(status in [:armed, :active, :paused] and expires_at <= ^now)
      |> Ankole.Ash.update_where(:expire)

    length(expired)
  end

  @doc """
  Returns the model-safe endpoint projection.
  """
  @spec model_projection(WebhookEndpoint.t()) :: map()
  def model_projection(%WebhookEndpoint{} = endpoint) do
    %{
      "id" => endpoint.id,
      "label" => endpoint.label,
      "mode" => endpoint.mode,
      "status" => Atom.to_string(endpoint.status),
      "automation_job_id" => Ankole.Signals.source_automation_job_id(endpoint),
      "expires_at" => Ankole.Attrs.datetime_iso8601(endpoint.expires_at),
      "created_at" => Ankole.Attrs.datetime_iso8601(endpoint.inserted_at)
    }
  end

  @doc """
  Calculates the digest stored for one plaintext callback token.
  """
  @spec token_digest(String.t()) :: String.t()
  def token_digest(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp create_attrs(attrs, token) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    {:ok,
     attrs
     |> Map.put_new("authorization_kind", "service")
     |> Map.put(
       "agent_uid",
       then(Map.get(attrs, "agent_uid"), fn uid ->
         if is_binary(uid), do: Ankole.PrincipalKey.canonicalize(uid), else: uid
       end)
     )
     |> Map.put("token_digest", token_digest(token))}
  end

  defp validate_expiry(%{"expires_at" => %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :webhook_expiry_must_be_future}
  end

  defp validate_expiry(_attrs, _now), do: {:error, :invalid_webhook_expiry}

  defp validate_public_target(%{"session_id" => session}) when is_binary(session) do
    case ExecutionTarget.parse(%{session_id: session}) do
      :error ->
        {:error, :invalid_signal_target}

      _ ->
        if Ankole.Sessions.Key.routable?(session), do: :ok, else: {:error, :invalid_signal_target}
    end
  end

  defp validate_public_target(_attrs), do: :ok

  defp cancel_locked_endpoint(endpoint, now) do
    cond do
      endpoint.status not in [:armed, :active, :paused] ->
        {:ok, %{status: :already_terminal, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- Ankole.Ash.update(endpoint, :expire, %{}) do
          {:ok, %{status: :already_terminal, webhook_endpoint: expired}}
        end

      true ->
        with {:ok, cancelled} <-
               Ankole.Ash.update(endpoint, :cancel, %{cancelled_at: now}) do
          {:ok, %{status: :cancelled, webhook_endpoint: cancelled}}
        end
    end
  end

  defp receive_locked(endpoint, plan, now) do
    cond do
      not Ankole.Tenants.accepting_work?(endpoint.tenant_id) ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      not Ankole.AutomationJobs.JobSources.live?(endpoint) ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      endpoint.status not in @active_statuses ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- Ankole.Ash.update(endpoint, :expire, %{}) do
          {:ok, %{status: :ignored, webhook_endpoint: expired}}
        end

      true ->
        with {:ok, delivery} <- Ankole.Signals.deliver_dispatch_in_tx(plan),
             {:ok, endpoint} <- maybe_mark_fired(endpoint, now) do
          run =
            Enum.find_value(delivery.receipts, fn receipt ->
              if receipt.automation_job_run_id,
                do: AutomationJobs.get_run_record(receipt.automation_job_run_id)
            end)

          {:ok,
           %{
             status: if(delivery.receipts == [], do: :ignored, else: :accepted),
             webhook_endpoint: endpoint,
             signal: List.first(delivery.signals),
             signals: delivery.signals,
             automation_job_run: run,
             deliveries: delivery.receipts
           }}
        end
    end
  end

  defp receipt_payload(endpoint, source_event_id, headers, body, now) do
    {encoded_body, encoding} = encode_body(body)

    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://signals-gateway/webhooks",
      "subject" => "webhook_endpoint:#{endpoint.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => "webhook.received",
      "data" => %{
        "webhook_endpoint" => %{
          "id" => endpoint.id,
          "label" => endpoint.label,
          "mode" => endpoint.mode
        },
        "headers" => allowlisted_headers(headers),
        "body" => encoded_body,
        "body_encoding" => encoding,
        "body_size" => byte_size(body),
        "received_at" => DateTime.to_iso8601(now),
        "reply_route" =>
          reject_nil_values(%{
            "binding_name" => endpoint.binding_name,
            "conversation_id" => endpoint.conversation_id,
            "provider_thread_id" => endpoint.provider_thread_id,
            "provider_message_id" => endpoint.provider_message_id
          }),
        "source_signal_id" => endpoint.source_signal_id,
        "source_provenance" => endpoint.source_provenance || %{}
      }
    }
  end

  defp maybe_mark_fired(%WebhookEndpoint{mode: "one_shot"} = endpoint, now),
    do: Ankole.Ash.update(endpoint, :fire, %{fired_at: now})

  defp maybe_mark_fired(%WebhookEndpoint{mode: "standing"} = endpoint, _now),
    do: {:ok, endpoint}

  defp lock_endpoint(endpoint_id, agent_uid, session_id) do
    with {:ok, endpoint_id} <- Ecto.UUID.cast(endpoint_id) do
      WebhookEndpoint
      |> Ash.Query.filter(id == ^endpoint_id)
      |> maybe_where_agent(agent_uid)
      |> maybe_where_session(session_id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {:rows, "signal_webhook_endpoints", :id})
    else
      :error -> nil
    end
  end

  defp lock_endpoint_by_token(token) do
    digest = token_digest(token)

    WebhookEndpoint
    |> Ash.Query.filter(token_digest == ^digest)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {:rows, "signal_webhook_endpoints", :id})
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) do
    agent_uid = String.downcase(agent_uid)
    Ash.Query.filter(query, agent_uid == ^agent_uid)
  end

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: Ash.Query.filter(query, session_id == ^session_id)

  defp maybe_active_only(query, false, _now), do: query

  defp maybe_active_only(query, true, now),
    do: Ash.Query.filter(query, status in ^@active_statuses and expires_at > ^now)

  defp allowlisted_header?("content-type"), do: true
  defp allowlisted_header?("x-hub-signature-256"), do: true
  defp allowlisted_header?("ce-" <> _name), do: true
  defp allowlisted_header?("x-github-" <> _name), do: true
  defp allowlisted_header?(_name), do: false

  defp encode_body(body) do
    if durable_text?(body),
      do: {body, "utf-8"},
      else: {Base.encode64(body), "base64"}
  end

  defp durable_text?(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp validate_token(token) when is_binary(token) do
    if Regex.match?(@token_pattern, token),
      do: :ok,
      else: {:error, :invalid_webhook_token}
  end

  defp validate_token(_token), do: {:error, :invalid_webhook_token}

  defp bounded_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_limit(_limit), do: 100

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  def job_source_operation_in_tx(job, :list, _) do
    endpoints =
      WebhookEndpoint
      |> Ash.Query.filter(owner_job_id == ^job.id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ankole.Ash.read!()

    deliveries =
      endpoints
      |> Enum.map(&"webhook-endpoint://#{&1.id}")
      |> Ankole.Signals.source_deliveries()

    {:ok,
     Enum.map(
       endpoints,
       &%{
         endpoint: &1,
         deliveries: Map.fetch!(deliveries, "webhook-endpoint://#{&1.id}")
       }
     )}
  end

  def job_source_operation_in_tx(job, :create, attrs) do
    attrs =
      attrs
      |> Map.take(~w(label expires_at mode event_format))
      |> Map.put_new("mode", "standing")
      |> Map.put_new("event_format", "raw")
      |> Map.merge(
        Ankole.Attrs.normalize_external_attrs(Ankole.Principals.WorkAccess.fields(job))
      )
      |> Map.merge(%{"owner_job_id" => job.id, "automation_job_id" => job.id})

    with {:ok, attrs} <- expiry(attrs),
         {:ok, prepared, token} <- prepare_endpoint(attrs, []),
         {:ok, result} <- create_endpoint_in_tx(prepared, token) do
      path =
        if prepared["event_format"] == "cloudevents",
          do: "/signals/v1/cloudevents/",
          else: "/webhooks/v1/event-callbacks/"

      {:ok, Map.put(result, :callback_path, path <> token)}
    end
  end

  def job_source_operation_in_tx(job, operation, %{"id" => id} = attrs) do
    endpoint =
      WebhookEndpoint
      |> Ash.Query.filter(id == ^id and owner_job_id == ^job.id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"signal_webhook_endpoints", id})

    case endpoint do
      nil -> {:error, :not_found}
      endpoint -> change_webhook(endpoint, operation, attrs)
    end
  end

  def job_source_operation_in_tx(_, _, _), do: {:error, :invalid_request}

  defp change_webhook(%{status: status}, operation, _)
       when status in [:cancelled, :expired, :fired] and operation in [:update, :pause, :resume],
       do: {:error, :webhook_terminal}

  defp change_webhook(endpoint, :update, attrs) do
    with {:ok, attrs} <- expiry(Map.take(attrs, ~w(label expires_at))),
         do: Ankole.Ash.update(endpoint, :configure, attrs)
  end

  defp change_webhook(%{status: :paused} = endpoint, :pause, _), do: {:ok, endpoint}
  defp change_webhook(endpoint, :pause, _), do: Ankole.Ash.update(endpoint, :pause, %{})

  defp change_webhook(endpoint, :resume, _) do
    cond do
      DateTime.compare(endpoint.expires_at, DateTime.utc_now()) != :gt ->
        {:error, :webhook_expired}

      endpoint.status in [:armed, :active] ->
        {:ok, endpoint}

      true ->
        Ankole.Ash.update(
          endpoint,
          if(endpoint.mode == "one_shot", do: :resume_armed, else: :resume_active),
          %{}
        )
    end
  end

  defp change_webhook(endpoint, operation, _) when operation in [:cancel, :delete] do
    if endpoint.status in [:cancelled, :expired, :fired],
      do: {:ok, endpoint},
      else: Ankole.Ash.update(endpoint, :cancel, %{cancelled_at: DateTime.utc_now(:microsecond)})
  end

  defp expiry(%{"expires_at" => value} = attrs) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> expiry(Map.put(attrs, "expires_at", dt))
      _ -> {:error, :invalid_webhook_expiry}
    end
  end

  defp expiry(%{"expires_at" => %DateTime{} = expires_at} = attrs) do
    if DateTime.after?(expires_at, DateTime.utc_now()),
      do: {:ok, attrs},
      else: {:error, :webhook_expiry_must_be_future}
  end

  defp expiry(attrs), do: {:ok, attrs}

  def job_source_ids(job_ids) do
    WebhookEndpoint
    |> Ash.Query.filter(owner_job_id in ^job_ids)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  def purge_job_sources_in_tx(ids) do
    WebhookEndpoint
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "signal_webhook_endpoints", :id})

    with {:ok, _} <-
           WebhookEndpoint |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.destroy_where(:remove),
         do: :ok
  end
end
