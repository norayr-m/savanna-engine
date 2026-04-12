# Pre-Computed Scenarios

Scenario files (.savanna) are too large for the git repository (100MB+ each).
They are distributed as **GitHub Release assets**.

## Download
Go to [Releases](../../releases) and download the .savanna files.

## Included Scenarios

| File | Frames | Size | Seed | Description |
|------|--------|------|------|-------------|
| scenario_001_seed42.savanna | ~500 | ~496MB | 42 | Default parameters, 1M grid |
| scenario_002_seed7 .savanna | — | — | 7 | (to be generated) |
| scenario_003_seed99.savanna | — | — | 99 | (to be generated) |

## Verification

Each scenario is deterministic. Re-run with the same seed:
```bash
swift run savanna-cli --seed 42 --ticks 500
```
The output should match frame-for-frame.

## File Format
See [INVENTORY.md](../INVENTORY.md) for the .savanna binary format spec.
