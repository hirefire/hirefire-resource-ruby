# Audit workspace

Scripts, snapshots, and raw results of the Ruby client audit. The plan, the map, the lens results, and the findings are in the canon under `hirefire-resource/ruby-audit/`. Nothing here ships: the gemspec packs `lib/` and three documents only.

Run every script with the first Ruby in `.tool-versions`, from the repository root, after `audit/bin/setup`.

| Path                  | Holds                                                                 |
| --------------------- | --------------------------------------------------------------------- |
| `bin/setup`           | Installs the bundle of every matrix cell and starts the test services |
| `bin/matrix-run`      | Runs every cell once, with coverage on request, and writes a summary  |
| `bin/matrix-summary`  | Combines the runs and names every test that failed in any of them     |
| `bin/coverage-report` | Merges line and branch coverage of all cells per file                 |
| `bin/public-api`      | Writes the public names and signatures by reflection                  |
| `bin/wire-goldens`    | Captures the ingest and lease requests, or checks them with `--check` |
| `bin/sandbox`         | Copies the tree to a throwaway directory, with its own services       |
| `baseline/`           | Coverage, the public API snapshot, and the wire golden copies         |
| `results/`            | Raw results of the matrix, mutation, fault, and soak runs             |
| `readers/`            | Reports of the second readers, one per lens                           |
| `evidence/`           | Tests and scripts that prove a finding, outside the regular suite     |
| `notes/`              | Working notes of the first read                                       |
