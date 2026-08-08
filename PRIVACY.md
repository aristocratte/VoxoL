# Privacy

VoxoL is designed so audio, transcripts and application context stay on the Mac after the
user explicitly installs the two runtime models. The shipped product must contain no telemetry,
account system, analytics SDK, API key or silent network request.

The Phase 0 application does not capture audio, inspect Accessibility content, retain history or
perform network requests. Development and conversion tools may access official upstream model
repositories only after an explicit developer command; those tools are not part of the delivered
application.

Future changes that touch audio, context, logs, storage or networking require privacy tests and an
architecture decision before merge. Secrets and user content must never be committed to this
repository.
