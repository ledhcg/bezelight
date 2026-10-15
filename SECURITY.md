# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability**
(<https://github.com/ledhcg/bezelight/security/advisories/new>). Do not open a public issue.
Expect an acknowledgement within a few days.

## Scope notes

Bezelight runs locally and sends nothing over the network. Areas worth a careful look:

- the hook helper and the Unix socket in `~/.bezelight` (mode 0600, one datagram per event);
- the installer that edits agent settings files (it backs up first and never rewrites a file it did not understand);
- screen and audio capture (never stored; frames are reduced to LED colors in memory).
