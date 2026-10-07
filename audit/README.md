# Audit workspace

Scripts, snapshots, and raw results of the Ruby client audit. The plan, the map, the lens results, and the findings are in the canon under `hirefire-resource/ruby-audit/`. Nothing here ships: the gemspec packs `lib/` and three documents only.

Run every script with the first Ruby in `.tool-versions`, from the repository root, after `audit/bin/setup`.

| Path                  | Holds                                                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `bin/setup`           | Installs the bundle of every matrix cell and starts the test services                                                  |
| `bin/matrix-run`      | Runs every cell once, with coverage on request, and writes a summary                                                   |
| `bin/matrix-summary`  | Combines the runs and names every test that failed in any of them                                                      |
| `bin/coverage-report` | Merges line and branch coverage of all cells per file                                                                  |
| `bin/public-api`      | Writes the public names and signatures by reflection                                                                   |
| `bin/wire-goldens`    | Captures the ingest and lease requests, or checks them with `--check`                                                  |
| `bin/sandbox`         | Copies the tree to a throwaway directory, with its own services                                                        |
| `bin/mutate`          | Changes `lib/` one small step at a time and runs the covering cells                                                    |
| `bin/mutation-groups` | Lists the surviving changes per file and method                                                                        |
| `bin/mutation-triage` | Puts every surviving change in one group, tied to a finding                                                            |
| `bin/fault-run`       | Runs the client against a local server that misbehaves in 21 ways                                                      |
| `bin/soak`            | Runs the client for a long time with faults and forks. `AUDIT_SOAK_DIAGNOSE=1` counts what stays alive after a full GC |
| `bin/stress-report`   | Writes the stress results as one Markdown document                                                                     |
| `bin/check-audit`     | Checks the map, the lens sections, the findings, and the triage                                                        |
| `baseline/`           | Coverage, the public API snapshot, and the wire golden copies                                                          |
| `results/`            | Raw results of the matrix, mutation, fault, soak, and lease runs                                                       |
| `readers/`            | Notes of the second reading, which replaced the second readers                                                         |
| `evidence/`           | Tests and scripts that prove a finding, outside the regular suite                                                      |
| `notes/`              | Working notes of the first read                                                                                        |

A test in `evidence/` that ends in `_test.rb` runs inside a sandbox with the gemfile of its cell, for example:

```sh
audit/bin/sandbox /tmp/sandbox --services
cd /tmp/sandbox && set -a && source .env && set +a
BUNDLE_GEMFILE=gemfiles/sidekiq_8.gemfile COVERAGE=false bundle exec ruby -Ilib:test audit/evidence/sidekiq_test.rb -n /evidence/
```

Each of these tests fails on purpose: it states the behavior that would be correct. The other files in `evidence/` are scripts that print a measurement, run with `ruby -Ilib`.
