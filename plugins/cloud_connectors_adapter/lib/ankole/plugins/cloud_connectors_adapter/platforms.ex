for {id, name} <- [
      {"gitlab", "GitLab"},
      {"typeform", "Typeform"},
      {"salesforce", "Salesforce"},
      {"trello", "Trello"},
      {"calendly", "Calendly"},
      {"google_analytics", "GoogleAnalytics"},
      {"googlecalendar", "GoogleCalendar"},
      {"stripe", "Stripe"},
      {"sentry", "Sentry"},
      {"zendesk", "Zendesk"},
      {"figma", "Figma"}
    ] do
  defmodule Module.concat(Ankole.Plugins.CloudConnectorsAdapter, name) do
    @moduledoc false
    @behaviour Ankole.Connectors.Connector
    alias Ankole.Plugins.CloudConnectorsAdapter.{Adapter, Catalog, Protocol, Webhooks}
    @id id
    def tools, do: Catalog.tools(@id)
    def call(tool, args, context), do: Adapter.call(@id, tool, args, context)
    def platform_application(secret), do: Protocol.platform_application(@id, secret)
    def validate_credentials(config, credentials), do: Protocol.validate(@id, config, credentials)

    def cloud_auth_params(config, _secret, credentials),
      do: Protocol.auth_params(@id, config, credentials)

    def scopes_satisfied?(required, granted, _config),
      do: Protocol.scopes_satisfied?(@id, required, granted)

    if id not in ~w(stripe sentry zendesk figma) do
      def oauth_authorize_url(config, secret, params),
        do: Protocol.authorize(@id, config, secret, params)

      def oauth_exchange(config, secret, params),
        do: Protocol.exchange(@id, config, secret, params)

      def refresh_token(config, secret, credentials),
        do: Protocol.refresh(@id, config, secret, credentials)
    end

    if id != "google_analytics" do
      def reconcile_trigger(config, secret, trigger, desired),
        do: Adapter.reconcile_trigger(@id, config, secret, trigger, desired)

      def webhook(config, secret, body, headers),
        do: Webhooks.receive(@id, config, secret, body, headers)

      def cloud_reconcile_trigger(config, credentials, endpoint, desired),
        do: Webhooks.reconcile(@id, config, credentials, endpoint, desired)

      def cloud_event(event_type, data), do: Webhooks.cloud_event(event_type, data)
    end
  end
end
