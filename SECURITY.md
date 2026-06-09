# BullX Security Policy

BullX takes the security of our software products and services seriously. If you believe you have found a security vulnerability in any BullX-owned repository, please report it to us as described below.

## Supported Versions

Use this section to tell people about which versions of your project are currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 0.x     | :white_check_mark: |


### How severity is determined

BullX reserves the right to make a final decision regarding the severity of a reported finding. Upon receipt of the finding, we will conduct an internal investigation and determine the severity of the finding by considering multiple factors including but not limited to:

- Common Vulnerability Scoring System
- The quantity of affected users and data
- The difficulty in exploiting
- Other, if any, mitigating factors or exploit scenario requirements


## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them to `sre@agentbull.cn` to report any security vulnerabilities. If possible, encrypt your message with our PGP key;

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

You should receive a response within 48 hours. If the issue is confirmed, we will release a patch as soon as possible depending on complexity but historically within a few days.

Please include the requested information listed below (as much as you can provide) to help us better understand the nature and scope of the possible issue:

- Type of issue (e.g. buffer overflow, SQL injection, cross-site scripting, etc.)
- Full paths of source file(s) related to the manifestation of the issue
- The location of the affected source code (tag/branch/commit or direct URL)
- Any special configuration required to reproduce the issue
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue, including how an attacker might exploit the issue

This information will help us triage your report more quickly.

## Preferred Languages

We prefer all communications to be in English or Chinese.

## Comments on this Policy

If you have suggestions on how this process could be improved please submit a pull request.