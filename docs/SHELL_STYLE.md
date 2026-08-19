# Shell Coding Convention

This project uses a consistent Bash style so test scripts remain safe, reviewable, and reusable.

## Rules

- Bash only: `#!/usr/bin/env bash`.
- Strict mode:

```bash
set -Eeuo pipefail
IFS=$'\n\t'
```

- 4-space indentation.
- `snake_case` function/local variable names.
- Global paths/constants are `readonly` where practical.
- Function-local variables are declared with `local` near the beginning of the function.
- Quote variable expansions unless intentional word splitting is required.
- Use `[[ ... ]]` for Bash conditionals and `(( ... ))` for arithmetic conditions.
- Avoid `eval`.
- Invalid CLI usage returns exit status 2.
- All loops are bounded or iterate over explicit finite collections.
- Persistent lab configuration belongs in `config.env`.
- Shared loading and validation belong in `scripts/lib/common.sh`.
- Runtime state belongs under `state/`; captures under `captures/`.
- Setup and cleanup must be repeatable, idempotent, and tolerate partial previous runs.
- Rollback traps ensure partial setup failures cleanly restore system state.
- Scripts never flush global nftables/iptables state and never replace the host default route.
- Refuse to move an interface that carries the host default route or existing IPv4 addresses.
- Do not hard-code product-specific management commands; expose them through `config.env`.
- Scripts should remain `shellcheck` friendly.
