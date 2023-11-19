## v1.0.0

* Switch to MIT license.
* `HireFire`:
  * Rename `HireFire::Resource` to `HireFire`. `HireFire::Resource` is now an alias of `HireFire` for backwards compatibility.
  * Add configuration option to specify a custom logger -- defaults to `Logger.new($stdout)`.
  * Add `dyno(:web)` configuration option. Offers an alternative (and preferred) way to collect and transmit Request Queue Time metrics to HireFire, without involving the Heroku Logplex and HireFire Logdrain. Enabling both `dyno(:web)` and `log_queue_metrics = true` results in `dyno(:web)` taking precedence. Requires `HIREFIRE_TOKEN` to be set.
* `HireFire::Macro::Sidekiq.job_queue_latency`:
  * Rename `.latency` to `.job_queue_latency`.
  * Take into account jobs in the scheduled and retry sets.
  * Accept the `:skip_scheduled` option (default: false).
  * Accept the `:skip_retries` option (default: false).
  * Accept multiple queues and raise an error when no queue is provided.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Sidekiq.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Accept `:server` (Boolean, default: false) to perform a query inside the Redis server using Lua.
  * Optimize client-side counting of `ScheduledSet` and `RetrySet`.
  * Raise an error when no queue is provided.
* `HireFire::Macro::GoodJob.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for GoodJob.
* `HireFire::Macro::GoodJob.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Accept the `:priority` option.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Delayed::Job.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for DelayedJob.
* `HireFire::Macro::Delayed::Job.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Stop accepting the `:mapper` option. Mapper is now inferred from the adapter.
  * Replace options `:min_priority` and `:max_priority` with `:priority` (Integer, Range, nil).
  * Raise an error when no queue is provided.
* `HireFire::Macro::Bunny.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Accept `:max_priority` in favor of `"x-max-priority"`.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Resque.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Take into account scheduled jobs (via resque-scheduled).
  * Take into account failed jobs that are scheduled to be retried (via resque-retry).
  * Raise an error when no queue is provided.
* `HireFire::Macro::Que.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for Que.
* `HireFire::Macro::Que.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Accept `:priority` option.
  * Raise an error when no queue is provided.
* `HireFire::Macro::QC.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for QC (Queue Classic).
* `HireFire::Macro::QC.job_queue_size`:
  * Rename `.queue` method to `.job_queue_size`.
  * Accept multiple queues.
  * Take into account scheduled jobs.
  * Raise an error when no queue is provided.
* Support
  * Drop support for Ruby 2.6.
  * Drop support for delayed_job 2.
  * Drop support for delayed_job_mongoid 2.
  * Drop support for que 0.
  * Drop support for que 1.
  * Drop support for qu.

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
  * Usage: `HireFire::Macro::Bunny.job_queue_size(queue, amqp_url: url, "x-max-priority": 10 )`

## v0.7.2

* Changed Que macro to query take into account scheduled jobs.

## v0.7.1

* Made entire library threadsafe.

## v0.7.0

* Made `HireFire.log_queue_metrics` optional. This is now disabled by default.
  * Enable by setting `log_queue_metrics = true`.
  * Required when using the `Manager::Web::Logplex::QueueTime` autoscaling strategy.
