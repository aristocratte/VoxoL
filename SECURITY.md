# Security policy

VoxoL is pre-release software. Do not use it for sensitive dictation until the relevant phase
gates and threat-model tests pass.

Report vulnerabilities privately through the repository host's security-advisory mechanism once
a remote repository exists. Do not include transcripts, audio, credentials or private context in
a public issue.

Every model artifact must be pinned, checksum-verified and smoke-tested before it can be marked
ready. Production logs must be content-free by default, and deterministic output must remain
available whenever model output is rejected.
