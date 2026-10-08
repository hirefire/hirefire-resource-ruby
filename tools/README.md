# Tools

Checks that go beyond the test suite. The suite shows that the code does what the tests say. These tools show whether the tests would catch a mistake, and how the client behaves when the server or the host misbehaves. Nothing here ships: the gemspec packs `lib/` and three documents only.

Run every script with the first Ruby in `.tool-versions`, from the repository root, after `tools/bin/setup`. They are not part of `rake check` or CI, because mutation testing and the soak take long. Run them before a release, and after a change to the threads, the wire format, or an adapter.

| Path                    | Holds                                                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `bin/setup`             | Installs the bundle of every matrix cell and starts the test services                                                  |
| `bin/sandbox`           | Copies the tree to a throwaway directory, with its own services                                                        |
| `bin/matrix-run`        | Runs every cell once in random order, with coverage on request, and writes a summary                                   |
| `bin/matrix-summary`    | Combines the runs and names every test that failed in any of them                                                      |
| `bin/coverage-report`   | Merges line and branch coverage of all cells per file                                                                  |
| `bin/mutate`            | Changes `lib/` one small step at a time and runs the cells that cover the changed line                                 |
| `bin/mutation-verdicts` | Reports the score per file and fails on a surviving change that has no verdict, or on a score below 90 percent         |
| `bin/mutation-groups`   | Lists the surviving changes per file and method                                                                        |
| `bin/fault-run`         | Runs the client against a local server that misbehaves in 21 ways                                                      |
| `bin/soak`              | Runs the client for a long time with faults and forks. `TOOLS_SOAK_DIAGNOSE=1` counts what stays alive after a full GC |
| `bin/public-api`        | Writes the public names and signatures by reflection                                                                   |
| `bin/public-api-diff`   | Compares the public names of a run with the golden copy                                                                |
| `bin/wire-goldens`      | Captures the ingest and lease requests, or checks them against the golden copies with `--check`                        |
| `baseline/`             | The golden copies of the public API and the wire requests, which the checks compare against                            |
| `lib/`                  | The code behind the scripts: the fake server, the fault and soak harnesses, the mutation generator and runner          |
| `results/`              | Where every script writes. Ignored by git                                                                              |

## Mutation testing

The runner is part of this directory and not an existing gem, for one reason: the suite runs in 23 gemfile cells, and a changed line has to run only in the cells that cover it. `bin/mutate` reads that from the coverage map, so `bin/matrix-run <run> --coverage` and `bin/coverage-report` come first.

A change that survives every test is either a missing test or a change that cannot alter a result. `lib/mutation/verdicts.rb` holds one rule with its reason for each change of the second kind.

## Golden copies

`baseline/` is tracked, because the checks compare against it. A change that alters a public name or a request on purpose regenerates the golden copy in the same commit.

## Results

No result is committed to this repository: no test output, coverage, mutation record, fault or soak number, and no report built from them. Every script writes under `tools/results/`, which git ignores. `TOOLS_RUN=<name>` sends a run to `tools/results/<name>/`.

Results worth keeping are stored in the canon, under `hirefire-resource/ruby-audit/results/`, without paths of the machine that produced them.
