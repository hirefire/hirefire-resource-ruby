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
