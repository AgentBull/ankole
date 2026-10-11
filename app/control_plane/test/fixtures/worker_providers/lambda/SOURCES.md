# Lambda MicroVM unit fixtures

The response values are synthetic. The paths, field names, required fields,
enums, and units come from the official sources below, read on 2026-10-08.
These fixtures do not prove AWS behavior.

- [Botocore service model](https://github.com/boto/botocore/blob/develop/botocore/data/lambda-microvms/2025-09-09/service-2.json),
  SHA-256 `6782d43f8839ad7342ebcd402c660db0ac2ece792b5877275cc85418285fb36a`.
  API version `2025-09-09`, REST JSON, SigV4 service `lambda`.
  The fixtures were checked against its required fields and enums.
  In particular, CPU architecture is `ARM_64`, not the OCI name `arm64`.
  The model declares image state `CREATION_FAILED`. A real 2 GiB image build
  returned `CREATE_FAILED` on 2026-10-08; its version returned `FAILED` with
  `An unknown error occurred.` The unit test rejects both image-state forms
  and keeps the exact returned state in the error. No cause is inferred from
  this generic platform error.
  A real account with an 8 GiB ARM64 quota returned HTTP 402
  `ServiceQuotaExceededException`. The retry test includes this response and
  requires the adapter to keep it retryable.
- [Image lifecycle and hooks](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images.html):
  build role, managed AL2023 image, snapshot entry, environment variables,
  capabilities, version patching, and the `/ready` path.
- [Launch and runtime hooks](https://docs.aws.amazon.com/lambda/latest/dg/microvms-launching.html):
  `/run` receives `microvmId` and the string `runHookPayload`.
  The SDK's payload field limit is 4096 bytes; a prose paragraph says 16384.
  The adapter uses the field limit.
- [Network connector service model](https://github.com/boto/botocore/blob/develop/botocore/data/lambda-core/2026-04-30/service-2.json):
  the `network-connector` ARN resource type and optional version suffix.
- [ECR authorization](https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_GetAuthorizationToken.html):
  JSON protocol target and response envelope for a private image registry.
  Its response uses `application/x-amz-json-1.1`. The HTTP fixture uses this
  media type so the test also checks the AWS response decoder.
- [SigV4 canonical request](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html):
  `host`, content type, and the `x-amz-*` headers belong in the signature.
  The request assertions check the signed header list for Lambda, S3, and ECR.
- [OCI Distribution specification](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)
  and [Bearer authentication](https://distribution.github.io/distribution/spec/auth/token/):
  manifest/index selection, config blobs, and public registry authentication.
- `aws_signature` 0.4.3 and `aws_credentials` 1.1.1 from
  [aws-beam](https://github.com/aws-beam): signing input and the default
  credential chain, including EKS Pod Identity.

Cloud checks still need a temporary AWS account session, S3 build bucket,
build IAM role, EFS, VPC connector, and a reachable control plane. They must
exercise termination and recreation, image replacement, NFS 4.1 directory
deletion, suspend/resume, hook timeout, and provider isolation.
