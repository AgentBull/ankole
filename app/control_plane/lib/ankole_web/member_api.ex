defmodule AnkoleWeb.MemberAPI do
  @moduledoc "Browser account operations with authenticated cookie responses."
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(AnkoleWeb.MeOperations)
    resource(AnkoleWeb.JSONAPI.PodRealtime)
  end

  json_api do
    authorize?(true)

    routes do
      base_route "/", AnkoleWeb.JSONAPI.PodRealtime do
        route(:get, "/realtime-token", :token, name: "podRealtimeToken")
      end

      base_route "/me", AnkoleWeb.MeOperations do
        route(:get, "/", :show, name: "podMe")
        route(:patch, "/", :update_profile, name: "updatePodProfile")

        route(:post, "/reauthentication", :begin_reauthentication,
          name: "reauthenticatePodMember"
        )

        route(:post, "/email/challenges", :request_email, name: "requestPodEmailBinding")

        route(:post, "/email/verifications", :verify_email,
          name: "verifyPodEmailBinding",
          modify_conn: &AnkoleWeb.BrowserAPI.apply_cookies/4
        )

        route(:delete, "/credentials/:id", :unbind, name: "unbindPodCredential")
        route(:delete, "/membership", :exit, name: "exitPod")
      end
    end
  end
end
