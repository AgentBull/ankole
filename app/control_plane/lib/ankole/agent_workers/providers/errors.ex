defmodule Ankole.AgentWorkers.Providers.Errors do
  @moduledoc "Projects provider validation and platform failures for operators."
  # The tags of the platform errors that provider kinds return from `check/1`.
  @platform_apis %{
    docker_api: "Docker Engine",
    kubernetes_api: "The Kubernetes API",
    cloudflare_adapter: "The Cloudflare adapter",
    vercel_api: "The Vercel API",
    lambda_api: "The AWS Lambda API",
    function_compute_api: "The Function Compute API"
  }
  @platform_connections %{
    docker_unreachable: "Docker Engine",
    kubernetes_request: "The Kubernetes API",
    cloudflare_adapter_unreachable: "The Cloudflare adapter",
    vercel_unreachable: "The Vercel API",
    lambda_unreachable: "The AWS Lambda API",
    function_compute_unreachable: "The Function Compute API"
  }

  def describe({:invalid_worker_provider_config, errors}),
    do: invalid("Worker provider YAML is invalid", errors)

  def describe(%Ecto.Changeset{} = changeset),
    do:
      invalid(
        "Worker provider is invalid",
        Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
      )

  def describe({:invalid_worker_provider_credential, name}),
    do:
      invalid("A required credential is missing", [
        %{path: "credentials.#{name}", message: "is required"}
      ])

  def describe({:invalid_worker_provider_credentials, message}),
    do: invalid("The credentials are invalid", [%{path: "credentials", message: message}])

  def describe(:lambda_credentials_unavailable),
    do:
      invalid("The control plane has no AWS credentials", [
        %{
          path: "credentials",
          message:
            "enter accessKeyId and secretAccessKey, or give AWS credentials to the control plane"
        }
      ])

  def describe({:worker_provider_credential_unreadable, name}),
    do:
      invalid("A stored credential cannot be decrypted", [
        %{path: "credentials.#{name}", message: "cannot decrypt this credential"}
      ])

  def describe({:unknown_worker_provider_credentials, names}),
    do:
      invalid(
        "Unknown credential fields",
        Enum.map(
          names,
          &%{path: "credentials.#{&1}", message: "is not declared by this provider kind"}
        )
      )

  def describe(:worker_provider_cluster_immutable),
    do:
      invalid("The Kubernetes cluster cannot change after creation", [
        %{
          path: "credentials.kubeconfig",
          message:
            "keep the cluster address and CA; a provider cannot change between in-cluster and remote access"
        }
      ])

  def describe(:invalid_worker_provider_kubeconfig),
    do:
      invalid("The kubeconfig has no valid current context", [
        %{
          path: "credentials.kubeconfig",
          message: "must name a valid cluster and current context"
        }
      ])

  def describe(:worker_provider_ca_unreadable),
    do:
      invalid("The kubeconfig CA file cannot be read", [
        %{path: "credentials.kubeconfig", message: "use readable certificate-authority data"}
      ])

  def describe(:unknown_worker_provider_kind),
    do: invalid("Unknown Worker provider kind", [%{path: "kind", message: "is not supported"}])

  def describe(:worker_runtime_not_configured),
    do: invalid("The Worker image and RuntimeFabric startup configuration are required")

  def describe({:missing, key}),
    do:
      invalid("A required field is missing", [
        %{path: to_string(key), message: "is required"}
      ])

  def describe({:kubernetes_permission_denied, verb, resource, reason}),
    do: invalid("Kubernetes denied #{verb} on #{resource}" <> suffix(": ", reason, ""))

  def describe({:kubernetes_credentials, message}),
    do: invalid("The Kubernetes credentials cannot be loaded: #{message}")

  # Lambda gives an AWS error code in place of a message.
  def describe({platform, status, message}) when is_map_key(@platform_apis, platform),
    do: describe({platform, status, nil, message})

  def describe({platform, status, code, message}) when is_map_key(@platform_apis, platform),
    do:
      invalid(
        "#{@platform_apis[platform]} returned HTTP #{status}" <>
          suffix(" (", code, ")") <> suffix(": ", message, "")
      )

  def describe({platform, %_{} = reason}) when is_map_key(@platform_connections, platform),
    do: invalid("#{@platform_connections[platform]} is unreachable: #{Exception.message(reason)}")

  def describe(_reason), do: :unknown

  defp invalid(message, details \\ []),
    do: {:invalid, message, details}

  defp suffix(_before, value, _after) when value in [nil, ""], do: ""
  defp suffix(before, value, after_value), do: "#{before}#{value}#{after_value}"
end
