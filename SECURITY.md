# Ankole Security Policy

We take the security of Ankole seriously. If you discover a security vulnerability in any Ankole repository, please report it privately using the instructions below.

## Supported Versions

Ankole is a self-hostable AgentOS designed for production use. Because public APIs do not carry a backwards-compatibility guarantee across releases, security fixes ship only on the latest `main` branch.

| Version | Supported          |
| ------- | ------------------ |
| >=1.0   | :white_check_mark: |

### How We Assess Severity

When we receive a vulnerability report, we investigate the finding internally and determine its severity based on:

- Common Vulnerability Scoring System (CVSS) metrics
- The scope of affected users, tenants, and stored data
- How difficult the issue is to exploit in a realistic deployment
- Any preconditions or mitigating controls that limit impact

Ankole retains final discretion over severity ratings.

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub issues, discussions, or pull requests.**

Email your report privately to `sre@agentbull.com`. Whenever possible, encrypt your message with our PGP public key:

```base64
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEaeOX2xYJKwYBBAHaRw8BAQdAlSXBTdVFg1DXgwuEwSB9A4hMeJL/o47opaln
xU1P+S60IEFnZW50QnVsbCBTUkUgPHNyZUBhZ2VudGJ1bGwuY24+iJMEExYKADsW
IQTnnzbeL9KGI9gF4hunv1gBF+vrBwUCaeOX2wIbAwULCQgHAgIiAgYVCgkICwIE
FgIDAQIeBwIXgAAKCRCnv1gBF+vrB0t/AP9YepQHu3xQOSZ8UtZPaZ3sEpjBGCVh
xYlWovHJ5HEl7wEAqHhiFW0dkcdWGZW0vdGBE8pGixoz/1tHh5XAIbR4fgO4OARp
45fbEgorBgEEAZdVAQUBAQdAMMvgFyNPJbyMqMaSbPxN+GF5nFGq2Ww3QRQp47tv
iWkDAQgHiHgEGBYKACAWIQTnnzbeL9KGI9gF4hunv1gBF+vrBwUCaeOX2wIbDAAK
CRCnv1gBF+vrB4LMAQCCQ+x2o8NRQ7UXiOpjuIrPyQ7cHGYU/qho6DhXR7iSmgEA
i9/38mOunY8XArLcNCp+dYPgeOZ30pzNDlohn+pg7ws=
=vRTS
-----END PGP PUBLIC KEY BLOCK-----
```

We aim to acknowledge reports within 48 hours. Once we confirm an issue, we work to ship a patch as quickly as its complexity allows—typically within a few days.

To help us triage and reproduce your finding quickly, include as much of the following detail as you can:

- Vulnerability class (for example, SQL injection, authentication bypass, cross-site scripting, or SSRF)
- Full repository paths to the affected source files
- Exact code revision (tag, branch, commit SHA, or permalink)
- Any non-default configuration needed to trigger the issue
- Step-by-step reproduction instructions
- Proof-of-concept code or request payloads, if available
- Concrete security impact and how an attacker could exploit the flaw

## Preferred Languages

We accept security reports in English or Chinese.

## Policy Feedback

If you have suggestions for improving this security policy, feel free to open a pull request.
