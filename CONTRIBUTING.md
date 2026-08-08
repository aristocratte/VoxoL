# Contributing

Work in small vertical slices that compile, test and expose observable behavior through a narrow
module interface. Add or update an ADR before a major architecture choice.

Before submitting a change:

```sh
./Scripts/verify.sh
```

Do not commit model weights, generated Core ML/MLX artifacts, audio recordings, transcripts,
credentials or private context. Do not add a runtime model, cloud SDK or Python process to the
application. Any proposed scope change requires explicit product approval.
