# Local verification

Final source was checked with Solidity 0.8.26 and the settings in `foundry.toml`.

- `forge build --sizes`: passed. All production contracts fit runtime and initcode limits; no unresolved library links.
- `forge test -vv`: **47 tests passed, 0 failed, 0 skipped**, across six suites.
- Three fuzz functions each ran 256 cases using the assignment seed pinned in `foundry.toml`.
- Stateful fee invariants ran **128 sequences / 8,192 calls / 0 reverts**, checking ETH conservation, exact fee-debt backing, treasury solvency, and fixed token supply/balance conservation.
- Result and failure callbacks passed with cold treasury storage and a 200,000-gas stipend. The result test uses nonzero URI bytes and verifies truncation to 96 bytes.
- `forge fmt --check`: passed.
- `python3 tools/check_bundle.py`: passed; ordinary delivered source, licenses and documentation total approximately **1.24 MB**, below the 8 MiB limit, and all Solidity imports resolve locally.
- Vendored source and license files were compared against the pinned upstream archives/raw source. Generated compiler files and caches were removed after checking.

| Contract | Runtime bytes | Creation bytes, before constructor arguments |
| --- | ---: | ---: |
| MediciToken | 1,503 | 2,440 |
| MediciHook | 8,344 | 31,020 |
| MediciTreasury | 18,637 | 19,058 |
| MediciFeeRouter | 2,413 | 2,726 |

The build/test results are local evidence, not an independent audit. Tests use actual v4 swap/liquidity accounting with mocked factory and Intake integration; they do not broadcast or depend on RPC access. Production launch rehearsal and independent review remain outside these checks.
