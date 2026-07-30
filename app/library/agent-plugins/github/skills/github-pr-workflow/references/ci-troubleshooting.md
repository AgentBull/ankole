# CI Troubleshooting

GitHub Actions logs are evidence about a failure, not permission to change an
unrelated surface. Start with the failed run and job:

```bash
gh run view <run-id> --repo "$GH_OWNER_REPO"
gh run view <run-id> --repo "$GH_OWNER_REPO" --log-failed
```

Classify the failure by its owning boundary:

- A test assertion can indicate a production defect, a stale expectation, or
  invalid setup. Read the test and owning contract before choosing.
- A compile, type, lint, or formatting failure names a local source or
  configuration mismatch. Reproduce the repository's declared command.
- A dependency or build failure belongs to the package manifest, lockfile,
  toolchain, or artifact source named by the log.
- An authentication or permission failure belongs to workflow permissions,
  repository policy, or missing operator configuration.
- A timeout or cancellation needs the last productive log event and job
  timing; it is not evidence of a generic retryable failure.

After a correction, run the affected local check and inspect the new GitHub
run. A successful rerun proves only that run; report any skipped or unrelated
checks separately.
