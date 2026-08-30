# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The library now pushes metrics to `https://data.hirefire.io`. HireFire no longer polls the app.
- Request queue time is sampled from HTTP traffic through the middleware. A web `dyno` line is not required.
- CPU activity is sampled automatically.
- Optional token-only setup with `HireFire.boot`. Existing `config.dyno` job queue blocks still work.
- Count of jobs still being processed (`job_queue_working`) for Sidekiq, Solid Queue, Delayed Job, Que, Good Job, and Queue Classic.
- Support Resque 3, Bunny 3.x, and resque-scheduler 5.
- Support Ruby 3.4 and 4.0.
- Support Hanami 3.
- Support Mongoid 9 for Delayed Job.
- `HireFire::Macro::Bunny.job_queue_size` accepts `connection:` again so a caller can reuse a long-lived Bunny session. A forked child drops the inherited session without closing it, so the parent keeps sampling.

### Changed

- Metrics are sent only when `HIREFIRE_TOKEN` is set.
- Job queue metrics are sampled by one process at a time.
- Job queue macros count queued jobs plus scheduled or retry jobs that are due. Jobs already being processed are no longer included in job queue size or job queue latency.
- Deprecated `.queue` aliases on Good Job and Resque still count jobs the way they did in 1.x (including jobs already being processed).
- Sidekiq job queue size (and deprecated `.queue`) no longer includes jobs that are already being processed. Pass `skip_working: false` to include them.
- Sidekiq job queue latency returns a Float.
- Required Ruby is 3.1+. Official Rails support is 7+.

### Deprecated

- If you use Logplex Request Queue Time, `config.log_queue_metrics = true` is deprecated. It still prints `[hirefire:router] queue=<N>ms`, so Logplex Request Queue Time keeps working. Switch to HireFire Request Queue Time (push, no logdrain):
  - Install hirefire-resource 2.0.0 or newer
  - Remove `config.log_queue_metrics = true`
  - In the HireFire UI, change the manager from `Logplex - Request Queue Time` to `HireFire - Request Queue Time`
  - Ensure `HIREFIRE_TOKEN` is set in the Heroku app env
- Bare `config.dyno(:web)` (no sampler) is deprecated. It does nothing. Request queue time is sampled automatically from HTTP traffic. You can remove the line. Leaving it does not break anything.

### Removed

- Serving `GET /hirefire/:token/info`.
- Official support for Ruby 2.7 and 3.0.
- Official support for Sidekiq 6, Good Job 2, Que 0, and Solid Queue 0.
- `HireFire::Macro::Bunny::ConnectionError`. Bunny connection failures raise `Bunny::Exception`.

### Fixed

- Bunny queue samples now fail within five seconds when RabbitMQ does not complete the handshake, instead of waiting on Bunny's longer defaults.
- Sidekiq job queue latency ignores malformed timestamps instead of treating them as the Unix epoch, and treats a future timestamp as zero.
- Sidekiq `server: true` counts due jobs in the current second the same way the client path does.
- Sidekiq `server: true` skips corrupt schedule or retry members instead of aborting the sample.
- Sidekiq `server: true` enumerates queues without scanning Redis keys.
- Deprecated Sidekiq `.queue(..., skip_working: false)` no longer counts jobs that have not started.
- Good Job latency orders by the earlier of scheduled and created time so immediate jobs are not sorted last.
- Good Job 3.0 to 3.15 no longer queries a discard column that those versions do not have.
- Resque all-queues size uses the queue list Redis already tracks.
- Resque named-queue size skips corrupt delayed payloads instead of aborting the sample.
- Que latency uses the database clock so a lagging app clock cannot return a negative value.
- Queue Classic returns its database connection to the pool after each sample.
- A forked child no longer closes the RabbitMQ connection it inherited, so job queue readings in the parent process are not interrupted.

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
