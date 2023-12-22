## v1.0.0

* `HireFire`:
  * Deprecate `HireFire::Resource`.
  * Use `HireFire` as the entrypoint to configure the gem. `HireFire::Resource` is now an alias for backwards compatibility.
  * Add configuration option to specify a custom logger. The logger defaults to `Logger.new($stdout)`.
  * Add `dyno(:web)` configuration option.
* `HireFire::Macro::Sidekiq.job_queue_latency`:
  * Deprecate `.latency`.
  * Introduce `.job_queue_latency` (replaces `.latency`).
  * Take into account jobs in the scheduled and retry sets.
  * Accept the `:skip_scheduled` option.
  * Accept the `:skip_retries` option.
  * Accept multiple queues.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Sidekiq.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Accept `:server` to perform a query inside the Redis server using Lua.
  * Optimize client-side counting of `ScheduledSet` and `RetrySet`.
  * Raise an error when no queue is provided.
* `HireFire::Macro::GoodJob.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for GoodJob.
* `HireFire::Macro::GoodJob.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Accept the `:priority` option.
  * Raise an error when no queue is provided.
* `HireFire::Macro::Delayed::Job.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for Delayed::Job.
* `HireFire::Macro::Delayed::Job.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Remove the `:mapper` option. Mapper is now inferred from the adapter.
  * Replace options `:min_priority` and `:max_priority` with `:priority` (Integer, Range, nil).
  * Raise an error when no queue is provided.
* `HireFire::Macro::Bunny.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Accept `:max_priority` (replaces `:"x-max-priority"`).
  * Raise an error when no queue is provided.
* `HireFire::Macro::Resque.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Consider scheduled jobs (resque-scheduled).
  * Consider failed jobs (resque-retry).
  * Raise an error when no queue is provided.
* `HireFire::Macro::Que.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for Que.
* `HireFire::Macro::Que.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Accept `:priority` option.
  * Raise an error when no queue is provided.
* `HireFire::Macro::QC.job_queue_latency`:
  * Add `.job_queue_latency` to measure job queue latency for QC (Queue Classic).
* `HireFire::Macro::QC.job_queue_size`:
  * Deprecate `.queue`.
  * Add `.job_queue_size` (replaces `.queue`).
  * Accept multiple queues.
  * Take into account scheduled jobs.
  * Raise an error when no queue is provided.
* Support
  * Add support for the latest versions of Ruby and the worker libraries.
  * Drop support for Ruby 2.6.
  * Drop support for delayed_job 2.
  * Drop support for delayed_job_mongoid 2.
  * Drop support for que 0.
  * Drop support for que 1.
  * Drop support for qu.
* Switch to MIT license.

### Migration - Configuration

The configuration method for the `hirefire-resource` gem has been updated. Previously, it was set up
as follows:

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

This change is backwards-compatible, meaning that your current configuration using
`HireFire::Resource` will continue to work for now. However, `HireFire::Resource` may be removed in
a future release, so we recommend updating to the new method at your earliest convenience.

### Migration - Macro Functions

All `.queue` and `.latency` macro functions have been renamed to `.job_queue_size` and
`.job_queue_latency` respectively. In addition, both functions now require you to explicitly pass in
one or more queue names, since they will no longer automatically infer which queues to monitor. This
change is due to the fact that automatic inference has previously led to unexpected results.

For example, if previously you were doing the following:

```rb
HireFire::Macro::Sidekiq.queue   # defaulted to all queues
# or
HireFire::Macro::Sidekiq.latency # defaulted to "default"
```

To maintain the same behavior, you must now explicitly pass in the queues that the worker dyno works on.

For example, the following Sidekiq worker:

```sh
worker: sidekiq -q critical -q default -q low
```

Would require the following call:

```rb
HireFire::Macro::Sidekiq.job_queue_size(:critical, :default, :low)
# or
HireFire::Macro::Sidekiq.job_queue_latency(:critical, :default, :low)
```

Depending on whether you're using the Job Queue Size or Job Queue Latency autoscaling strategy.

This applies to all macro functions.

### Migration - Request Queue Time

We are updating the method of collecting and dispatching request queue time metric data. Previously,
the HireFire middleware intercepted requests to process relevant information, which was then logged
to stdout and picked up by the Heroku Logplex for forwarding to HireFire's Logdrain. Moving forward,
while the middleware will continue to process these metrics, it will now dispatch them directly from
the web dynos to HireFire's servers, bypassing the Heroku Logplex entirely.

This change offers several advantages:

- Reduced computational overhead
- Reduced log noise
- No log forwarding
- No reliance on the availability of the Heroku Logplex
- Simpler integration

To implement this change, do the following:

1. Remove `config.log_queue_metrics = true` from the hirefire configuration file.
2. Insert `config.dyno(:web)` into the hirefire configuration file.
3. Ensure that the `HIREFIRE_TOKEN` environment variable is added to your Heroku application.
4. Deploy these changes to Heroku.

The `HIREFIRE_TOKEN` environment variable is available in your HireFire account under the dyno
manager settings. To check if it's already set, run:

```sh
heroku config -a <application> | grep HIREFIRE_TOKEN
```

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
