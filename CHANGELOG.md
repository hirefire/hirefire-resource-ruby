# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Zero-config bootstrap: `HireFire.boot` (empty `configure`), Rails railtie starts the dispatcher when a token is present, always-on request queue time on the HTTP middleware path, and always-on CPU when process identity resolves. Local `config.dyno` job-queue blocks remain the escape hatch for custom probes and legacy root.
- Lease collection plans: grant body `{ version, job_queues }` is parsed and executed via allowlisted queue macros (`sidekiq`, `solid_queue`, `good_job`, `que`, `queue_classic`, `delayed_job`, `resque`, `bunny`). Per-name precedence: adapter set runs plan macros (local ignored), adapter null runs the local sampler under the lease strategy, unknown adapter/strategy skips that name without local fallback.
- Always-lease race entry when local job-queue samplers exist or any allowlisted job-queue library is loaded. Empty/unexecutable grants are not held (dropped at TTL) while the request loop stays alive so a later UI plan is discovered.
- Additive post-boot `configure`: late local job-queue samplers re-evaluate lease policy and start the job-queue loop on demand without `reset`.
- Multi-strategy reports under one process name (for example `rqt` and `cpu` on `web`). Same name may declare different source kinds without `DuplicateDynoError`.
- YARD documentation on the core public API (entrypoint, configuration, dispatcher, sources, middleware, errors), extending the coverage the queue macros already had.
- `config.dyno(name, &block)` is the only local declaration API: name `"web"` implies http, a sampler block is job-queue metrics. No `tracking:` keyword (CPU is always-on; RQT is traffic/platform-armed).
- CPUActivity metrics (the `:cpu` collector): self-samples the dyno's CPU utilization once per second as a bare per-second reading on the wire. CPU time is read from a cgroup counter where one exists (cgroup v2/v1), else by summing `/proc/[pid]/stat` across the PID namespace (whole-dyno CPU where no cpu cgroup is exposed), else the stdlib process clock (dev/macOS). Normalized by the cgroup CPU quota where present, else the Cedar shared-dyno entitlement inferred from the dyno's memory limit (512 MB → 1 core, 1 GB → 2 cores), else the processor count (dedicated dynos and dev machines). Gated by process identity (`HIREFIRE_SERVICE_NAME`, the Heroku `DYNO` name, both Cedar `web.1` and Fir pod-name formats, or `RENDER_SERVICE_NAME`) so a process only reports CPU under its own dyno name. Unresolved identity disables CPU with a loud log rather than raising.
- Web liveness claims (heartbeats and backfilled empty seconds) require a resolved process identity that matches the RQT report name. Mismatched identity suppresses synthesis so idle workers do not claim web seconds (RPM coverage). Unresolved identity never synthesizes liveness and never invents a default report name such as `"web"` — only real identifiers (`DYNO`, `RENDER_SERVICE_NAME`, `HIREFIRE_SERVICE_NAME`, or explicit `dyno(:web)`) are used.
- Web metrics now claim every second between dispatches: seconds with no buffered samples are backfilled with explicit empty arrays (capped at 60 seconds, advancing only on successful delivery), so the server receives a complete per-second record. "Alive with zero traffic" is reported as zero rather than left as a gap. Required for the RequestsPerMinute autoscaling strategy, whose coverage guard holds scaling when seconds go unreported.
- The dispatcher is now fork-aware: a forked worker (e.g. Puma cluster with `preload_app!`) detects that the inherited dispatcher thread did not survive the fork and starts a fresh one on the first request, instead of silently never dispatching. Each child also re-issues its own lease identity and drops any inherited grant, so forked workers do not all poll job queues under the parent identity, and discards the job-queue/CPU samples the parent buffered but had not yet dispatched, so parent and child do not both report the same pre-fork second.
- The dispatcher runs web/CPU dispatch and job-queue sampling on separate loops, so a slow or hung job-queue sampler (a job backend blocking with no timeout) can no longer stall metric delivery. Lease renewal and job-queue sampling run on their own loop, dispatch on another. A hung sampler stops renewing its lease, so the server hands job-queue sampling to a healthy process. Within each loop, stages stay isolated: a raising sampler is logged and costs one sample window, and a failed lease renewal is logged, revokes the local grant, and waits a full TTL before retrying.
- The middleware and dispatcher start are crash-safe: the per-request bookkeeping is wrapped so an internal failure (including the OS refusing a thread when the dispatcher starts) is logged and swallowed instead of raising into the host application's request or aborting boot from `HireFire.configure`. A failed dispatcher-thread spawn leaves the dispatcher retryable rather than latched as "running" with no loop, and the downstream app call stays outside the guard so the host app's own exceptions still propagate.
- Metric dispatch and lease requests reuse a single persistent HTTPS connection (keep-alive) instead of opening a fresh TCP and TLS handshake per request. On the roughly once-per-second dispatch path this removes most of the per-request round-trips and the handshake CPU spent on the host process. A keep-alive socket the peer closes while idle is transparently reconnected and retried once (both endpoints are idempotent, so the retry is safe).
- Job-queue samplers are validated: a raising sampler is isolated per job-queue source, and non-numeric, negative, or non-finite return values are dropped with a logged error instead of being sent. `BigDecimal`/`Rational` values (e.g. from an ActiveRecord `sum`) are coerced to a float so they reach the server as numbers rather than JSON strings it would drop.
- Declaring a second http process via `config.dyno` raises (request metrics come from this process's own http traffic, so only one http source can exist per process). Duplicate-name detection is case-insensitive, matching the identity gates.
- `X-Request-Start` parsing now handles the nginx (`t=` + epoch seconds) and Apache (`t=` + epoch microseconds) formats in addition to Heroku's epoch milliseconds, and ignores unparseable or implausible values instead of producing an absurd queue-time sample.
- Timestamped buffers are bounded: when dispatch is starved (network outage), web/CPU seconds older than the 60-second server acceptance window are pruned at insert time, and job-queue samples keep only the latest value per name.
- A buffered payload that would exceed the server's **32 KB** (`32_768`) body limit is dropped, and dispatch resumes from the current second instead of retrying a payload that can never be delivered. The web watermark advances past the dropped seconds so they are left unclaimed (missing data) rather than backfilled as "alive with zero traffic".
- All transport errors (DNS, refused/reset connections, TLS) are mapped to `HireFire::Client::RequestError` and handled uniformly.
- A CPU usage-source switch mid-flight (e.g. a cgroup file disappearing) now re-baselines and skips one second instead of emitting a fabricated `0.0` sample.
- Support Bunny 3.x. `HireFire::Macro::Bunny` works unchanged against both 2.x and 3.x.
- Support resque-scheduler 5. `HireFire::Macro::Resque` works unchanged against both resque-scheduler majors.

### Changed

- `HireFire::Macro::QC` (Queue Classic) JQL and JQS are waiting-only: due jobs (`scheduled_at` ≤ now) that are unlocked (`locked_at` null). Locked (working) jobs are no longer counted in size or latency. No `skip_working` flag (unlike Sidekiq). Deprecated `.queue` is aligned the same way (no longer uses QC's full-table `count`). Readings are lower while jobs are locked, which is correct for waiting-only autoscaling.
- `HireFire::Macro::Delayed::Job` JQL and JQS are waiting-only: due jobs (`failed_at` null, `run_at` ≤ now) that are unlocked (`locked_at` null). Locked (working) jobs are no longer counted in size or latency. No `skip_working` flag (unlike Sidekiq). Deprecated `.queue` is aligned the same way. Expired-lock reclaim via `max_run_time` is not applied in v1.
- `HireFire::Macro::Resque.job_queue_size` is waiting-only: live enqueued lists + due delayed (score ≤ now, including resque-retry once due). Working worker payloads are no longer counted. JQL stays unsupported. No `skip_working` flag (unlike Sidekiq). Deprecated `.queue` is unchanged (still live + in-progress, no delayed).
- `HireFire::Macro::SolidQueue` JQL and JQS are waiting-only: ready + due scheduled only. Claimed (working) and blocked (concurrency throttle, including expired) are no longer counted in size or latency. No `skip_working` flag (unlike Sidekiq).
- `HireFire::Macro::Sidekiq.job_queue_size` (and deprecated `.queue`) default `skip_working` is now **true**: JQS counts only the waiting set (live + due scheduled + due retry) and no longer includes in-flight jobs. Pass `skip_working: false` to restore the old include-working behavior (flag kept through 2.0).
- Required Ruby is **3.1+** (`required_ruby_version`). Floor matches `Process._fork` (full prefork parent/child hooks without a polyfill). CI matrix is 3.1 / 3.2 / 3.3 / 3.4 / 4.0 (Rails 8 / Sidekiq 8 appraisals excluded on 3.1). Further floor raises can ship on a **minor** (gemspec + Bundler filter old Rubies); see knowledge-base `hirefire-resource/ruby.md`.
- Terminology: **name** (process), **source** (how samples are made), **strategy** (wire). Metric sources live under `HireFire::Source::` with fully capitalized acronyms: `Source::HTTP`, `Source::CPU`, `Source::JobQueue` / `Source::JobQueues`. Config uses `configuration.http` / `configuration.job_queues`, `http_source`, `rqt_enabled?` / `rqt_liveness?`. Process name `"web"` and platform web-role detection are unchanged. Wire codes stay `rqt` / `cpu` / `jql` / `jqs`.
- RQT arming is traffic-first (middleware sample), plus optional `config.dyno(:web)`, plus optional platform web-role hints: Heroku process type `web` after Cedar/Fir `DYNO` strip, or Render `RENDER_SERVICE_TYPE=web`. Pre-traffic idle heartbeats no longer arm from `HIREFIRE_SERVICE_NAME=web` alone (avoids workers mis-labeled as web). Other platforms wait for the first request unless `dyno(:web)` is declared.
- Ingest payload is nested only: `{ "name", "metrics": { strategy → { sec → [values…] } } }` with strategies `rqt`, `cpu`, `jql`, and `jqs`. Top-level `sample` / `samples` are no longer emitted.
- Job-queue samples are time-series under `metrics.jql` / `metrics.jqs` (bare numbers per second on the wire), tagged from the lease plan strategy rather than untyped gauges.
- The gem is now push-based: job-queue metrics are pushed outbound to `data.hirefire.io` instead of being polled via `/hirefire/<token>/info`, and web request-queue-time moves from `logdrain.hirefire.io` to `data.hirefire.io`. Restricted-egress networks must allowlist `data.hirefire.io` (outbound) or metrics silently stop.
- Metric dispatch and lease requests now always connect directly, ignoring the `http_proxy`/`https_proxy` environment variables that Ruby's `Net::HTTP` would otherwise honor. This matches the Python and Node clients and prevents an ambient proxy from silently intercepting the token-bearing metrics traffic.

### Removed

- `config.service` and all `tracking:` keywords (`:http`, `:cpu`). Zero-config covers RQT and CPU; lease plans cover UI-driven job queues; `config.dyno` remains for local job-queue samplers and optional `web` http registration (legacy/root until plans fully manage client config).
- Drop support for Sidekiq 6, Good Job 2, Que 0, and Solid Queue 0. These are end-of-life or pre-1.0 releases. The macros may still work against them, but only the current and one-major-back releases are tested and supported (Sidekiq 7+, Good Job 3+, Que 1+, Solid Queue 1+).

### Fixed

- Lease plan entries whose adapter cannot sample the plan strategy (Bunny/Resque + `jql`) are skipped without calling the macro every sample tick. Log once per name+adapter+strategy. Such entries do not count as sampleable for lease hold decisions (avoids holding a grant that can never produce that metric).
- Process identity env values (`HIREFIRE_SERVICE_NAME`, `DYNO`, `RENDER_SERVICE_NAME`, `RENDER_SERVICE_TYPE`) strip leading/trailing whitespace; whitespace-only values are treated as absent (same paste hygiene as the token).
- Middleware falls back to `X-Queue-Start` when `X-Request-Start` is present but blank or whitespace-only (empty string no longer blocks the fallback).
- Local job-queue `find_by_name` is case-insensitive (matching config duplicate-name rules) and still returns the canonically declared name for emit.
- `HireFire::Macro::Sidekiq.job_queue_latency` decodes `enqueued_at` / `created_at` by type (Float epoch seconds vs Integer epoch milliseconds) instead of by `Sidekiq::VERSION`. Residual pre-8 Float payloads left in Redis after a Sidekiq 8 upgrade no longer under-report latency by about 1000x.
- Load the stdlib `set` library from `utility.rb` so queue normalization does not raise `NameError` in processes that never required `Set` via another gem.
- `HireFire::Macro::GoodJob` size and latency count only ready jobs (`finished_at` and `performed_at` both null), matching GoodJob's queued notion. Terminal rows finished without a perform (including discard-before-run) no longer inflate backlog when `error_event` is absent or null.
- Prefork parent (Puma `preload_app!`, Unicorn master) stops the dispatcher after `Process._fork` without a final flush, so the master no longer keeps claiming empty web liveness under the workers' process name. Children still restart via the existing child hook / middleware.
- Dispatcher `stop` joins each loop for a fixed timeout and abandons (does not `Thread#kill`) a hung sampler so clean shutdown stays bounded. Final flush remains best-effort. `at_exit` still stops the dispatcher for a last flush on process exit.

- After a fork, the keep-alive HTTP client abandons the inherited connection without calling `finish` on the parent's socket FD (avoids corrupting the parent under `preload_app!`).
- Dispatcher `stop` sets a stopping gate so concurrent `start` cannot race the final flush and client close.
- `Process._fork` hook restarts the dispatcher in worker-only children that never hit middleware; `at_exit` stops the dispatcher on clean process exit.
- RQT buffer stores sum+count per second (compact wire `[mean, n]` or `[]` heartbeat). Non-RQT strategies send bare numbers. Client and server payload cap is 32 KB.
- After fork, `discard_inherited` clears the buffer (including any early `rqt` sample); dispatch pacing and RQT watermark reset in the child.
- Unresolved identity disables CPU with a once-warn log (not silently).
- Whitespace-only tokens are treated as absent.
- `ensure_job_queue_loop` takes a lock-free fast path when the job-queue thread is already alive.
- Resque delayed-queue paging uses a score cursor instead of an offset `LIMIT` (avoids O(n²) Redis work on large delayed sets).
- Sidekiq server-side (Lua) working-job count now excludes jobs with a future `run_at`, matching the client-side filter.
- Bunny plan connection options strip and ignore blank `HIREFIRE_BUNNY_URL` / `HIREFIRE_AMQP_URL` values.
- Plan queue lists log when truncated; invalid lease plan entries are logged when skipped.
- HTTP metric and lease requests now set `write_timeout` to the same 5-second budget as connect and read, so a peer that accepts then stalls during the request body cannot pin the dispatch loop for the stdlib's 60-second write default.
- An empty token (`""` in code or `HIREFIRE_TOKEN=""`) is treated as absent: the dispatcher does not start, middleware does not sample, and no empty `HireFire-Token` is sent. Assigning `config.token = ""` also forces reporting off when the env var is set.
- Dispatcher loop threads bind to a start generation, so a hung loop that outlives `stop`'s join cannot resume work after a later `start` (matching the Python and Node clients).
- Malformed cgroup CPU usage, `/proc/[pid]/stat`, and CPU quota readings now fall through to the next source instead of parsing to zero. A zero usage baseline could report a spurious CPU spike on the next real reading, and a zero quota silently disabled CPU sampling.
- Internal dispatch pacing, lease renewal, and the CPU utilization delta now measure elapsed time on a monotonic clock, so a system clock adjustment (e.g. an NTP step) no longer skews the dispatch cadence, lease renewal, or a CPU reading. The metric timestamps themselves stay wall-clock, as the server requires.
- A user-supplied logger that raises from its logging method (a custom logger, or the default one writing to a closed stream) is now caught rather than propagated, so it can no longer escape a dispatcher or job-queue loop guard and halt metric reporting, or abort boot from `HireFire.configure`.
- `HireFire::Macro::GoodJob.job_queue_latency` orders by `COALESCE(scheduled_at, created_at)`. On older GoodJob schemas an immediate job has a `NULL` `scheduled_at`, which sorted last and hid an old immediate job behind a newer scheduled one. Reported latency was too low and may be (correctly) higher after this fix.
- `HireFire::Macro::Sidekiq.job_queue_size(server: true)`: the Lua script enumerates queues via `SMEMBERS queues` instead of `KEYS queue:*` (which scans the whole keyspace and double-counted numeric-string queue names) and pages the scheduled/retry sets by index instead of `ZRANGEBYSCORE … LIMIT offset` (quadratic, and could stall Redis on a large backlog). `max_scheduled` is applied exactly (per entry, not rounded up to a 1000-entry page) and shares the client-side semantics: omitted/`nil` means no limit, `0` (and negatives) means count none. The corrected de-duplication can lower a previously double-counted size.
- `HireFire::Macro::Sidekiq.job_queue_latency` returns a `Float` for the enqueued component as well, instead of truncating it to whole seconds, matching the documented return type and Sidekiq's own latency calculation.
- `HireFire::Macro::Que` (and its deprecated `.queue`) bind queue names as SQL parameters instead of interpolating them. The previous escaping was inert under PostgreSQL's default `standard_conforming_strings`, so a queue name containing a quote raised a syntax error, and the deprecated method did no escaping at all.
- `HireFire::Macro::QC` (Queue Classic) binds each queue name as its own placeholder instead of passing a single `{a,b}` array literal, which mis-parsed any queue name containing a comma into several names and matched none of them.
- `HireFire::Macro::GoodJob` detects the `error_event` column from the live schema rather than the gem version. The column was added in GoodJob 3.16, so the previous `>= 3.0` check produced SQL referencing a missing column on GoodJob 3.0 to 3.15 and on gem upgrades whose migration had not run.
- `HireFire::Macro::Resque` enumerates queues via `Resque.queues` (`SMEMBERS`) instead of `KEYS queue:*`, avoiding a full-keyspace scan on every all-queues size check.
- `HireFire::Macro::Bunny.job_queue_size` no longer masks broker errors: querying a missing queue raises `Bunny::NotFound` instead of the `Bunny::ChannelAlreadyClosed` that previously came from closing the broker-closed channel (which also leaked the connection). The channel and connection closes are isolated, and the connection is closed if opening the channel fails.
- `HireFire::Macro::Bunny.job_queue_size` accepts a `connection:` option to reuse a long-lived `Bunny::Session` instead of opening a new connection (a full TCP + AMQP handshake) on every call. The supplied connection is left open for the caller and takes precedence over `amqp_url`.

## [1.0.8] - 2025-08-04

### Fixed

- Fix issue with range notation in ActiveRecord queries for old Rails versions that caused Delayed Job and Good Job macros to always return 0.

## [1.0.7] - 2025-03-24

### Added

- Add support for Sidekiq 8.

## [1.0.6] - 2024-12-12

### Fixed

- Ensure that discarded jobs are not used when measuring queue size and latency with Good Job v3 and v4.

## [1.0.5] - 2024-11-15

### Added

- Support solid_queue 1.x.

### Changed

- Increase process name length constraint from 30 to 63.

## [1.0.4] - 2024-07-26

### Added

- Add support for `good_job ~> 4`, for the `job_queue_size`, `job_queue_latency` and `queue` (deprecated) macros.

## [1.0.3] - 2024-05-23

### Added

- Add support for `que ~> 0` and `que ~> 1`, in addition to `que ~> 2`, for both the `job_queue_size` and `job_queue_latency` macros.

## [1.0.2] - 2024-03-13

### Added

- Add support for dashes in `HireFire::Worker` names to match the Procfile process naming format. `HireFire::Worker` is implicitly used when configuring HireFire using the `HireFire::Configuration#dyno` method.

## [1.0.1] - 2024-02-01

### Fixed

- Fix issue where jobs that were enqueued using `sidekiq < 7.2.1` and then processed with `sidekiq >= 7.2.1` (after updating) resulted in a `NoMethodError: undefined method 'queue' for Hash` error during checkups.

## [1.0.0] - 2024-01-23

### Added

- Use `HireFire` as the primary configuration entrypoint (`HireFire::Resource` kept as a backward-compatible alias).
- Add a configurable logger option, defaulting to `Logger.new($stdout)`.
- Introduce `dyno(:web)` for the new `HireFire - Request Queue Time` autoscaling strategy.
- Add SolidQueue support (`.job_queue_size`, `.job_queue_latency`).
- Add `.job_queue_size` / `.job_queue_latency` macros across all adapters (Sidekiq, GoodJob, Delayed::Job, Bunny, Resque, Que, QC), replacing the deprecated `.queue` / `.latency`.
- `HireFire::Macro::Sidekiq.job_queue_latency` considers scheduled and retry sets, accepts `:skip_scheduled` / `:skip_retries`, accepts multiple queues, and infers all queues when none are given.
- `HireFire::Macro::Sidekiq.job_queue_size` accepts `:server` to perform the lookup on the Redis server using Lua, and optimizes client-side counting of the scheduled and retry sets.
- `HireFire::Macro::Resque.job_queue_size` considers scheduled (`resque-scheduler`) and failed (`resque-retry`) jobs.
- `HireFire::Macro::QC.job_queue_size` accepts multiple queues and considers scheduled jobs.

### Changed

- Switch to the MIT license.
- `HireFire::Macro::Bunny.job_queue_size`: `:amqp_url` now defaults, in order, to `AMQP_URL`, `RABBITMQ_URL`, `RABBITMQ_BIGWIG_URL`, `CLOUDAMQP_URL`, and `amqp://guest:guest@localhost:5672`. Queue size is measured in passive mode to avoid queue configuration conflicts, and an error is raised when no queue is provided.
- Support the latest versions of Ruby and all integrations.

### Deprecated

- Deprecate `HireFire::Resource` (use `HireFire`).
- Deprecate the `.queue` and `.latency` macros across all adapters (use `.job_queue_size` / `.job_queue_latency`).

### Removed

- `HireFire::Macro::Delayed::Job.job_queue_size`: remove the `:mapper` option (now inferred from the adapter) and the `:min_priority` / `:max_priority` options.
- `HireFire::Macro::Bunny.job_queue_size`: remove the `:"x-max-priority"`, `:connection`, and `:durable` options.
- Drop support for Ruby 2.6, delayed_job 2, delayed_job_mongoid 2, que 0 and 1, and qu.

## [0.10.1] - 2022-10-20

### Added

- Add redis 5 (gem) support to HireFire::Macro::Resque

## [0.10.0] - 2021-12-14

### Added

- Support Latency (Sidekiq)

### Changed

- Rename the "quantity" property to "value" in JSON response ("quantity" is still supported)

## [0.9.1] - 2021-09-17

### Added

- Support GoodJob > 2.2 where Job class is renamed to Execution

## [0.9.0] - 2020-10-17

### Added

- Add `skip_working` to Sidekiq macro

### Changed

- Use separate queries for Que 0.x and 1.x

## [0.8.1] - 2020-09-19

### Fixed

- Correct GoodJob macro to not count finished jobs.

## [0.8.0] - 2020-09-10

### Added

- Add GoodJob macro for `good_job` adapter. https://github.com/bensheldon/good_job

## [0.7.5] - 2020-08-30

### Fixed

- Fix compatibility issue with Que 1.x (backwards-compatible with Que 0.x).

## [0.7.4] - 2020-01-29

### Fixed

- Attempt to fix an issue where the STDOUT IO Stream has been closed for an unknown reason.
  - This resulted in errors in an application with `log_queue_metrics` enabled after a random period of time.

## [0.7.3] - 2019-11-20

### Added

- Added priority queue support for bunny message count.
  - Allows for passing in the `x-max-priority` option when opening up a queue to check the messages remaining.
  - Usage: `HireFire::Macro::Bunny.queue(queue, amqp_url: url, "x-max-priority": 10 )`

## [0.7.2] - 2019-07-13

### Changed

- Changed Que macro to query take into account scheduled jobs.

## [0.7.1] - 2018-11-22

### Fixed

- Made entire library threadsafe.

## [0.7.0] - 2018-11-06

### Changed

- Made `HireFire::Resource.log_queue_metrics` optional. This is now disabled by default.
  - Enable by setting `log_queue_metrics = true`.
  - Required when using the `Manager::Web::Logplex::QueueTime` autoscaling strategy.
