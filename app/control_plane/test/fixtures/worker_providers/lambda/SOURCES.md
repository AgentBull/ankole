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

Cloud checks need a temporary AWS account session, S3 build bucket, build IAM
role, EFS, VPC connector, and a reachable control plane. The complete storage
suite exercises termination and recreation, image replacement, NFS 4.1 directory
deletion, suspend/resume, and provider isolation. The `drive_vfs` selection uses
one Agent and one image to check actual mounts and freeze/thaw; shared file
semantics run locally. See the commands in CONTRIBUTING.md.

## Live Drive verification, 2026-11-02

The focused run used `us-west-2`, ARM64, 4096 MiB, EFS, the production Lambda
adapter, and a public HTTPS/WebSocket control plane. The adapter requested
`additionalOsCapabilities: ALL`. The OCI image was
`966239516738.dkr.ecr.us-west-2.amazonaws.com/ankole-vfs-1102@sha256:0fdf41a65bd4084e72cd8803ebc7ea4f2eaa0b0c5d1d80ff771d382585bbba54`;
the AWS image was `ankole-test-c1a89687531d4f4f`.

To avoid rebuilding an existing cloud fixture, this invocation copied the
repository's focused test body and reused its dedicated tenant, Agent, image,
and MicroVM. Only fixture setup and teardown differed:

```sh
MIX_TEST_PARTITION=lambda_worker_vfs_delivery_1102_1530 bun run test \
  /tmp/ankole-lambda-vfs-1102/focused_reuse_test.exs --only drive_vfs --trace
```

All behavioral assertions passed: real FUSE admission, mounted ChatDrive writes,
AWS suspension for 65 seconds, the same instance and incarnation after resume,
and reading and appending to the same conversation's existing file. The real
Worker executed commands and delivered byte-exact attachments through the Lark
adapter to its protocol fixture. No model or platform fixture replaced the
Lambda, FUSE, DAV, or Files adapter. The run took 190.9 seconds. Its log is
`/tmp/ankole-lambda-vfs-1102/test-focused-reuse.log`.

This is not a passing complete ExUnit run: teardown tried to delete a new fake
model provider while the reused Agent's model profiles still referenced it
(`provider_in_use`). The test requested real MicroVM termination. Earlier full
storage-suite attempts also did not pass, and image replacement and provider
isolation were not completed in this acceptance.

The live log exposed a shared thaw-ordering race: credential refresh could reach
the control plane before renewed Worker admission and receive 401. The Worker
now waits for admission before refresh. This final change was verified locally
against the real Phoenix/WebSocket protocol, including a simulated 65-second
clock gap with the old socket still open: 8 integration tests and 29 transport
unit tests passed. Worker type checking passed. The final ordering fix was not
uploaded for another AWS image build.

Cleanup was verified through AWS reads: every test MicroVM was terminated; the
test images, ECR repository, S3 build bucket, EFS, network connector, security
group, and both IAM roles were absent. The reused VPC, subnet, and NAT were left
untouched. The dedicated test database partitions, both local tunnels, and
temporary credential files were removed. This also removed the reused fixture's
model-profile references. Verification records are
`/tmp/ankole-lambda-vfs-1102/cleanup-verified.json` and
`/tmp/ankole-lambda-vfs-1102/cleaned-databases.json`.
