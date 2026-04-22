# Conventions

- **Helm chart changes require unit tests.** When adding or modifying values, templates, or rendered output in `chart/`, add a corresponding assertion in `chart/tests/*_test.yaml` (run with `helm unittest chart`). Exceptions: pure refactors that don't change rendered output, comment/whitespace-only edits.
- **Helm chart changes require a docs update.** When values, features, or rendered behavior change in `chart/`, update `docs/usages.md` (option reference, examples, and — if relevant — the alpha overlay section). Exceptions: internal refactors with no user-visible change (helper renames, comment-only edits).
