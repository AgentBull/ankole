defmodule Ankole.AppConfigure.Site do
  @moduledoc "The site administration routes of the settings registry."
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.AppConfigure.SiteOperations)
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/app-configurations", Ankole.AppConfigure.SiteOperations do
        route(:get, "/", :console_list, name: "list_site_app_configurations")
        route(:get, "/:key", :console_show, name: "get_site_app_configuration")
        route(:put, "/:key", :console_update, name: "update_site_app_configuration")
        route(:delete, "/:key", :console_delete, name: "reset_site_app_configuration")

        route(:post, "/:key/decryptions", :console_decrypt,
          name: "decrypt_site_app_configuration"
        )
      end
    end
  end
end
