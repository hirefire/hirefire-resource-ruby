## v1.1.0

Push-based metrics. The gem now collects worker, web request-queue-time, and CPU metrics and pushes them outbound to `data.hirefire.io`, replacing the 1.x hybrid (HireFire polled the app's `/hirefire/<token>/info` endpoint for worker metrics; web request-queue-time was pushed to `logdrain.hirefire.io`). **This release is backwards-compatible: every existing 1.x configuration keeps working unchanged — upgrade by bumping the gem.**

### Upgrading

* **No configuration change is required.** `config.dyno(:web)` and `config.dyno(:worker) { ... }` parse and route exactly as before. The backend detects the agent version on the first push and transparently reads the pushed metrics instead of polling. The `HireFire::Resource` alias, all macros (including the deprecated `.queue` / `.latency`), `HIREFIRE_TOKEN`, `HIREFIRE_VERBOSE`, the Railtie, and Ruby `>= 2.7` are all retained.
* **Restricted-egress networks must allowlist `data.hirefire.io` (outbound).** This is the one non-transparent part of the upgrade. The wire path changes: worker metrics flip from **inbound** (HireFire polled your app) to **outbound** (the gem pushes to `data.hirefire.io`), so worker-only apps no longer need a reachable web process — but it is a new egress path. Web request-queue-time moves its destination from `logdrain.hirefire.io` to `data.hirefire.io`. If you allowlist outbound destinations (or previously whitelisted HireFire's inbound poller IPs), add `data.hirefire.io` before upgrading, or metrics will silently stop flowing while your config still looks correct. Open-egress apps (the vast majority) need no action.

### Added

* `config.service(name, tracking: nil, &block)` — a platform-neutral way to declare what a process tracks, for any platform (Heroku, Render, DigitalOcean, …). The name carries no meaning, so what to track is always explicit: `config.service(:web, tracking: :http)` for request metrics, `config.service(:worker) { ... }` for job metrics (the block is the signal), `config.service(:clock, tracking: :cpu)` for CPU. Passing both `tracking:` and a block, or neither, raises. `config.dyno` is now exactly `config.service` plus the Heroku Procfile convention that the `web` name implies `:http`.
* `config.dyno` accepts an optional `tracking: :cpu` keyword — `config.dyno(:web, tracking: :cpu)`, `config.dyno(:clock, tracking: :cpu)` — to report CPU under that dyno name. The name still implies request metrics for `web` and job metrics when a block is given, so the 1.x forms are unchanged. `:cpu` is the only value `config.dyno` accepts (the request- and job-metric acronyms add nothing on the client and are unnecessary); use `config.service(name, tracking: :http)` if you need to declare an http process under a non-`web` name.
* CPUActivity metrics (the `:cpu` collector): self-samples the dyno's CPU utilization once per second and pushes it in the per-second samples format. CPU time is read from a cgroup counter where one exists (cgroup v2/v1 — Heroku Fir, Render, Docker, K8s), else by summing `/proc/[pid]/stat` across the PID namespace (whole-dyno CPU on Heroku Cedar, which exposes no cpu cgroup), else the stdlib process clock (dev/macOS). Normalized by the cgroup CPU quota where present, else the Cedar shared-dyno entitlement inferred from the dyno's memory limit (512 MB → 1 core, 1 GB → 2 cores), else the processor count (dedicated dynos and dev machines). Gated by process identity (`HIREFIRE_SERVICE_NAME`, the Heroku `DYNO` name — both Cedar `web.1` and Fir pod-name formats — or `RENDER_SERVICE_NAME`) so a process only reports CPU under its own dyno name; unresolved identity disables CPU with a loud log rather than raising.
* Web liveness claims (heartbeats and backfilled empty seconds) are now gated by process identity: when the process's identity resolves and does not match the declared web dyno name, only real request samples are delivered and no liveness is synthesized. This prevents idle worker, one-off, and console processes from claiming web seconds — which could satisfy the RequestsPerMinute coverage check during a web outage and read it as zero traffic instead of missing data. When identity cannot be resolved, behavior is unchanged.
* Web metrics now claim every second between dispatches: seconds with no buffered samples are backfilled with explicit empty arrays (capped at 60 seconds, advancing only on successful delivery), so the server receives a complete per-second record — "alive with zero traffic" is reported as zero rather than left as a gap. Required for the RequestsPerMinute autoscaling strategy, whose coverage guard holds scaling when seconds go unreported.
* The dispatcher is now fork-aware: a forked worker (e.g. Puma cluster with `preload_app!`) detects that the inherited dispatcher thread did not survive the fork and starts a fresh one on the first request, instead of silently never dispatching.
* Dispatcher tick stages are isolated: a failing lease renewal or a raising job sampler no longer prevents the stages after it (CPU sampling, metric dispatch) from running. A raising sampler is logged and costs one sample window; a failed lease renewal is logged, revokes the local grant, and waits a full TTL before retrying.
* Worker samplers are validated: a raising sampler is isolated per worker, and non-numeric, negative, or non-finite return values are dropped with a logged error instead of being sent.
* Declaring a second http process now raises, under any name and across both `config.dyno` and `config.service` (request metrics come from this process's own http traffic, so only one http collector can exist per process). Duplicate-name detection spans both methods and is case-insensitive, matching the identity gates.
* `X-Request-Start` parsing now handles the nginx (`t=` + epoch seconds) and Apache (`t=` + epoch microseconds) formats in addition to Heroku's epoch milliseconds, and ignores unparseable or implausible values instead of producing an absurd queue-time sample.
* Timestamped buffers are bounded: when dispatch is starved (network outage), web/CPU seconds older than the 60-second server acceptance window are pruned at insert time, and worker samples keep only the latest value per name.
* A buffered payload that would exceed the server's 64 KB body limit — only reachable after a sustained delivery outage combined with a very high per-process request rate — is dropped, and dispatch resumes from the current second instead of retrying a payload that can never be delivered. The web watermark advances past the dropped seconds so they are left unclaimed (missing data) rather than backfilled as "alive with zero traffic".
* All transport errors (DNS, refused/reset connections, TLS) are mapped to `HireFire::Client::RequestError` and handled uniformly.
* A CPU usage-source switch mid-flight (e.g. a cgroup file disappearing) now re-baselines and skips one second instead of emitting a fabricated `0.0` sample.

### Behavioral changes (macro fixes)

This release also lands the accumulated job-queue macro fixes. **Some of these change the reported value** — a few are corrections that read _higher_ than before (most notably GoodJob latency). That can nudge a threshold- or ratio-based autoscaler the first time the corrected value is reported; it is the macro becoming accurate, not the new push transport misbehaving. Review these if you autoscale on the affected adapters:

* `HireFire::Macro::GoodJob.job_queue_latency` orders by `COALESCE(scheduled_at, created_at)`. On older GoodJob schemas an immediate job has a `NULL` `scheduled_at`, which sorted last and hid an old immediate job behind a newer scheduled one; reported latency was too low and may be (correctly) higher after this fix.
* `HireFire::Macro::Sidekiq.job_queue_size(server: true)`: the Lua script enumerates queues via `SMEMBERS queues` instead of `KEYS queue:*` (which scans the whole keyspace and double-counted numeric-string queue names) and pages the scheduled/retry sets by index instead of `ZRANGEBYSCORE … LIMIT offset` (quadratic, and could stall Redis on a large backlog). `max_scheduled` is applied exactly (per entry, not rounded up to a 1000-entry page) and shares the client-side semantics: omitted/`nil` means no limit, `0` (and negatives) means count none. The corrected de-duplication can lower a previously double-counted size.
* `HireFire::Macro::Sidekiq.job_queue_latency` returns a `Float` for the enqueued component as well, instead of truncating it to whole seconds — matching the documented return type and Sidekiq's own latency calculation.
* `HireFire::Macro::Que` (and its deprecated `.queue`) bind queue names as SQL parameters instead of interpolating them. The previous escaping was inert under PostgreSQL's default `standard_conforming_strings`, so a queue name containing a quote raised a syntax error — and the deprecated method did no escaping at all.
* `HireFire::Macro::QC` (Queue Classic) binds each queue name as its own placeholder instead of passing a single `{a,b}` array literal, which mis-parsed any queue name containing a comma into several names and matched none of them.
* `HireFire::Macro::GoodJob` detects the `error_event` column from the live schema rather than the gem version. The column was added in GoodJob 3.16, so the previous `>= 3.0` check produced SQL referencing a missing column on GoodJob 3.0–3.15 and on gem upgrades whose migration had not run.
* `HireFire::Macro::Resque` enumerates queues via `Resque.queues` (`SMEMBERS`) instead of `KEYS queue:*`, avoiding a full-keyspace scan on every all-queues size check.
* `HireFire::Macro::Bunny.job_queue_size` no longer masks broker errors: querying a missing queue raises `Bunny::NotFound` instead of the `Bunny::ChannelAlreadyClosed` that previously came from closing the broker-closed channel (which also leaked the connection). The channel and connection closes are isolated, and the connection is closed if opening the channel fails.
* `HireFire::Macro::Bunny.job_queue_size` accepts a `connection:` option to reuse a long-lived `Bunny::Session` instead of opening a new connection (a full TCP + AMQP handshake) on every call; the supplied connection is left open for the caller and takes precedence over `amqp_url`.
* Add Bunny 3.x to the test matrix. `HireFire::Macro::Bunny` works unchanged against the new client; both 2.x and 3.x are now covered.
* Bump the `resque_3` appraisal to `resque-scheduler ~> 5`. resque-scheduler 5 requires `resque >= 3.0`, so `resque_2` stays on `~> 4`; the two appraisals now cover both resque-scheduler majors. `HireFire::Macro::Resque` works unchanged — the scheduled-jobs storage contract is identical.

## v1.0.8

* Fix issue with range notation in ActiveRecord queries for old Rails versions that caused Delayed Job and Good Job macros to always return 0.

## v1.0.7

* Add support for Sidekiq 8.

## v1.0.6

* Ensure that discarded jobs are not used when measuring queue size and latency with Good Job v3 and v4.

## v1.0.5

* Increase process name length constraint from 30 to 63.
* Add tests for `solid_queue ~> 1`.
* Drop tests for `ruby ~> 2.7`.

## v1.0.4

* Add support for `good_job ~> 4`, for the `job_queue_size`, `job_queue_latency` and `queue` (deprecated) macros.

## v1.0.3

* Add support for `que ~> 0` and `que ~> 1`, in addition to `que ~> 2`, for both the `job_queue_size` and `job_queue_latency` macros.

## v1.0.2

* Add support for dashes in `HireFire::Worker` names to match the Procfile process naming format. `HireFire::Worker` is implicitly used when configuring HireFire using the `HireFire::Configuration#dyno` method.

## v1.0.1

* Fix issue where jobs that were enqueued using `sidekiq < 7.2.1` and then processed with `sidekiq >= 7.2.1` (after updating) resulted in a `NoMethodError: undefined method 'queue' for Hash` error during checkups.

## v1.0.0

* `HireFire`:
  * Deprecate `HireFire::Resource`.
  * Use `HireFire` as the primary entrypoint to configure the gem. `HireFire::Resource` is now an alias for backward compatibility.
  * Add a configuration option to specify a custom logger, defaulting to `Logger.new($stdout)`.
  * Introduce the `dyno(:web)` configuration option for integration with the upcoming autoscaling strategy `HireFire - Request Queue Time`.
* `HireFire::Macro::SolidQueue`:
  * Add support for [SolidQueue](https://github.com/basecamp/solid_queue) with `.job_queue_latency` and `.job_queue_size` for latency and size measurement.
* `HireFire::Macro::Sidekiq.job_queue_latency`:
  * Deprecate `.latency`.
  * Introduce `.job_queue_latency` (replacing `.latency`).
  * Consider jobs in the scheduled and retry sets.
  * Accept the `:skip_scheduled` and `:skip_retries` options.
  * Accept multiple queues.
  * Infer all queues when none are specified.
* `HireFire::Macro::Sidekiq.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
  * Accept `:server` to perform the lookup on the Redis server using Lua.
  * Optimize client-side counting of `ScheduledSet` and `RetrySet`.
* `HireFire::Macro::GoodJob.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for GoodJob.
* `HireFire::Macro::GoodJob.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
* `HireFire::Macro::Delayed::Job.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for Delayed::Job.
* `HireFire::Macro::Delayed::Job.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
  * Remove the `:mapper` option. Mapper is now inferred from the adapter.
  * Remove `:min_priority` and `:max_priority` options.
* `HireFire::Macro::Bunny.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
  * Remove the `:"x-max-priority"` option.
  * Remove the `:connection` and `:durable` options.
  * `:amqp_url` option now defaults, in order, to `AMQP_URL`, `RABBITMQ_URL`, `RABBITMQ_BIGWIG_URL`, `CLOUDAMQP_URL`, and `"amqp://guest:guest@localhost:5672"`.
  * Measure job queue size in passive mode to avoid queue configuration conflicts.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Resque.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
  * Consider scheduled jobs (`resque-scheduled`).
  * Consider failed jobs (`resque-retry`).
* `HireFire::Macro::Que.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for Que.
* `HireFire::Macro::Que.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
* `HireFire::Macro::QC.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for QC (Queue Classic).
* `HireFire::Macro::QC.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replacing `.queue`).
  * Accept multiple queues.
  * Consider scheduled jobs.
* Support:
  * Add support for the latest versions of Ruby and all integrations.
  * Drop support for Ruby 2.6.
  * Drop support for delayed_job 2.
  * Drop support for delayed_job_mongoid 2.
  * Drop support for que 0 and 1.
  * Drop support for qu.
* Switch to MIT license.

### Migration - Configuration

The configuration method for the `hirefire-resource` gem has been updated. Previously, it was set up as follows:

```rb
HireFire::Resource.configure do |config|
  # existing configuration
end
```

The new configuration method is:

```rb
HireFire.configure do |config|
  # existing configuration
end
```

This change is backward-compatible, meaning that your current configuration using `HireFire::Resource` will continue to work for now. However, `HireFire::Resource` may be removed in a future release, so we recommend updating to the new method at your earliest convenience.

### Migration - Macro Functions

All `.queue` and `.latency` functions have been deprecated. Although they will continue to work, they are no longer supported and may be removed in a future release. We recommend migrating to the new `.job_queue_size` and `.job_queue_latency` functions. Note that we've streamlined these functions' arguments for consistency as much as possible, and options may have been added, removed, or changed.

Almost all functions now infer all existing queues when the `*queues` argument is left empty. For example:

```rb
HireFire::Macro::Sidekiq.job_queue_size # Measures queue size across all queues
HireFire::Macro::Sidekiq.job_queue_latency # Measures maximum latency across all queues
```

If your worker operates on all queues (assuming critical, default, low are all queues), for example:

```sh
worker: sidekiq -q critical -q default -q low
```

Then you can simply configure the macro as follows to measure latency across all queues:

```rb
dyno(:worker) do
  HireFire::Macro::Sidekiq.job_queue_latency
end
```

Or to measure queue size across all queues:

```rb
dyno(:worker) do
  HireFire::Macro::Sidekiq.job_queue_size
end
```

If your workers each operate on a subset of queues, for example:

```sh
worker: sidekiq -q critical -q default -q low
mailer: sidekiq -q mailer
```

The corresponding new function calls would be:

```rb
dyno(:worker) do
  HireFire::Macro::Sidekiq.job_queue_latency(:critical, :default, :low)
  # or: HireFire::Macro::Sidekiq.job_queue_size(:critical, :default, :low)
end

dyno(:mailer) do
  HireFire::Macro::Sidekiq.job_queue_latency(:mailer)
  # or: HireFire::Macro::Sidekiq.job_queue_size(:mailer)
end
```

Choose the appropriate module and function based on the worker library you are using and the autoscaling strategy you have implemented, whether it is Job Queue Size or Job Queue Latency. For more details on the available options per function, see the documentation.

### Migration - Request Queue Time

We are introducing a new autoscaling strategy called `HireFire - Request Queue Time`. This strategy uses the same metric as the `Logplex - Request Queue Time` strategy. The primary difference is that while the Logplex strategy requires the HireFire middleware to write the request queue time data to stdout and have the Heroku Logplex forward that data to HireFire via a Logdrain, the new strategy directly dispatches this data from the web dyno to HireFire, bypassing the Heroku Logplex entirely.

This strategy offers several advantages:

- Simpler integration.
- Elimination of log forwarding, resulting in:
  - Reduced log size.
  - Decreased log noise.
  - Fewer points of failure (i.e., Heroku Logplex availability).

To switch to this strategy:

1. Remove `config.log_queue_metrics = true` from your HireFire configuration file.
2. Insert the line `config.dyno(:web)` into your HireFire configuration file.
3. Ensure that the `HIREFIRE_TOKEN` environment variable is set in your Heroku application.
4. Deploy these changes to Heroku.
5. Switch the autoscaling strategy of the Dyno Manager in your HireFire account from `Logplex - Request Queue Time` to `HireFire - Request Queue Time`.

You can find the `HIREFIRE_TOKEN` environment variable in your HireFire account under the Dyno Manager settings. To verify if it's already set in your Heroku application, run:

```sh
heroku config -a <application> | grep HIREFIRE_TOKEN
```

Note: The `Logplex - Request Queue Time` strategy will continue to be available as an option.

## v0.10.1

* Add redis 5 (gem) support to HireFire::Macro::Resque

## v0.10.0

* Support Latency (Sidekiq)
* Rename the "quantity" property to "value" in JSON response ("quantity" is still supported)

## v0.9.1

* Support GoodJob > 2.2 where Job class is renamed to Execution

## v0.9.0

* Add `skip_working` to Sidekiq macro
* Use separate queries for Que 0.x and 1.x
* Remove `# encoding: utf-8` magic comments
* Add `# frozen_string_literal: true` magic comments

## v0.8.1

* Correct GoodJob macro to not count finished jobs.

## v0.8.0

* Add GoodJob macro for `good_job` adapter. https://github.com/bensheldon/good_job

## v0.7.5

* Fix compatibility issue with Que 1.x (backwards-compatible with Que 0.x).

## v0.7.4

* Attempt to fix an issue where the STDOUT IO Stream has been closed for an unknown reason.
  * This resulted in errors in an application with `log_queue_metrics` enabled after a random period of time.

## v0.7.3

* Added priority queue support for bunny message count.
  * Allows for passing in the `x-max-priority` option when opening up a queue to check the messages remaining.
  * Usage: `HireFire::Macro::Bunny.queue(queue, amqp_url: url, "x-max-priority": 10 )`

## v0.7.2

* Changed Que macro to query take into account scheduled jobs.

## v0.7.1

* Made entire library threadsafe.

## v0.7.0

* Made `HireFire::Resource.log_queue_metrics` optional. This is now disabled by default.
  * Enable by setting `log_queue_metrics = true`.
  * Required when using the `Manager::Web::Logplex::QueueTime` autoscaling strategy.
