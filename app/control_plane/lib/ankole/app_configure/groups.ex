defmodule Ankole.AppConfigure.Groups do
  @moduledoc "Closed Console editing tasks whose values must commit together."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Registry

  @prefixes %{
    "brain" => "brain.",
    "observability" => "observability.traces.",
    "otp" => "authn.email.",
    "smtp" => "authn.email.mail",
    "turnstile" => "saas.turnstile.",
    "pod-access" => "pod.allow_external_guests"
  }

  def keys(group) do
    case @prefixes[group] do
      nil ->
        []

      prefix ->
        Registry.list_definitions()
        |> Enum.filter(&String.starts_with?(&1.key, prefix))
        |> Enum.reject(&(group == "otp" and &1.key == "authn.email.mail"))
        |> Enum.map(& &1.key)
    end
  end

  def managed?(key),
    do:
      String.starts_with?(key, "ai_agent.library.") or
        Enum.any?(Map.values(@prefixes), &String.starts_with?(key, &1))

  # Authorization remains per key, including reset permission for a removal.
  def permissions(args, _attributes, _resource, _action) do
    updates =
      for key <- Map.keys(args["values"] || %{}),
          do: {"site_console:app_configuration:#{key}", "update"}

    resets =
      for key <- args["reset_keys"] || [], do: {"site_console:app_configuration:#{key}", "reset"}

    if updates ++ resets == [],
      do: [{"site_console:app_configurations", "update"}],
      else: updates ++ resets
  end

  def validate("observability", read), do: Ankole.Observability.validate_settings(read)

  def validate("turnstile", read) do
    with {:ok, enabled} <- read.("saas.turnstile.enabled") do
      if enabled do
        with {:ok, site} when is_binary(site) and site != "" <- read.("saas.turnstile.site_key"),
             {:ok, secret} when is_binary(secret) and secret != "" <-
               read.("saas.turnstile.secret_key"),
             do: :ok,
             else: (_ -> {:error, :incomplete_turnstile_configuration})
      else
        :ok
      end
    end
  end

  def validate(_group, _read), do: :ok

  def after_commit(scope, keys) do
    if "pod.allow_external_guests" in keys, do: Ankole.Pod.Config.broadcast_guest_access(scope)

    :ok
  end

  def prepare_value("smtp", "authn.email.mail", value, read) when is_map(value) do
    if Map.has_key?(value, "password") do
      {:ok, value}
    else
      case read.("authn.email.mail") do
        {:ok, %{"password" => password}} -> {:ok, Map.put(value, "password", password)}
        {:ok, _} -> {:ok, value}
        error -> error
      end
    end
  end

  def prepare_value(_group, _key, value, _read), do: {:ok, value}

  def mail_test(settings, recipient) do
    with true <-
           is_binary(recipient) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, recipient),
         {:ok, settings} <-
           prepare_value(
             "smtp",
             "authn.email.mail",
             settings,
             &AppConfigure.get_by_key(&1, scope: :global)
           ),
         {:ok, _settings} <- Ankole.Authn.Config.mail(settings) do
      Ankole.Authn.Mailer.send_test(recipient, mail: settings)
    else
      false -> {:error, :invalid_test_recipient}
      error -> error
    end
  end
end
