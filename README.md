## HireFire Integration Library for Ruby Applications

This gem integrates Ruby applications with HireFire's autoscalers on Heroku. It
reports app metrics so HireFire can autoscale web and worker processes, unlocking
metric-based autoscaling such as Request Queue Time, Requests Per Minute, CPU
Activity, Job Queue Latency, and Job Queue Size.

**Supported runtimes:**

- Ruby 3.1+

**Supported web frameworks:**

- Rails 7+
- Sinatra 3+
- Hanami 2+
- Rack 2+

**Supported worker libraries:**

- Solid Queue 1+
- Good Job 3+
- Delayed Job (Active Record 4+, Mongoid 3+)
- Sidekiq 7+
- Resque 2+ (size only, no job queue latency)
- Que 1+
- Queue Classic 4+
- Bunny 2+ (size only, no job queue latency)

Ruby 3.1+ is required and tested for the library core, Rack, Rails 7, Sidekiq 7, Bunny, and Resque 2. Worker-library cells that boot through Rails 8 in CI run on Ruby 3.2+. Older versions may still work, but are not officially supported.

**Documentation:**

Public API prose is YARD on the consumer-facing surface. Published gems are browsable on [rubydoc.info](https://www.rubydoc.info/gems/hirefire-resource). Locally: `bundle exec rake doc`. Changelog lives in [CHANGELOG.md](CHANGELOG.md).

---

Since 2011, HireFire has helped over 1,500 companies autoscale more than 5,000 [Heroku] applications across 10,000+ web and worker dynos.

HireFire autoscales web and worker processes based on the metrics that match the work: request queue time or requests per minute for web, job queue latency or job queue size for workers, and CPU activity for any compute-bound processes. Capacity follows demand, so you scale up when the app is busy and down when it is idle.

Learn more at the [home page][HireFire].

---

## Development

Requires [Docker](https://www.docker.com/) and [mise](https://mise.jdx.dev/). PostgreSQL, MongoDB, Redis, and RabbitMQ for the macro tests run in containers, and mise installs the pinned Ruby versions from `.tool-versions`. `bin/services up` starts them on Docker-assigned free host ports recorded in a git-ignored `.env` (read by the test suite). `bin/services down` stops them and removes `.env`. Because the ports are assigned fresh at startup, multiple worktrees can run side by side without conflicting with each other or with any system-wide databases.

- Run `bin/setup` to prepare the environment.
- Run `bin/services up` / `bin/services down` to start / stop PostgreSQL, MongoDB, Redis, and RabbitMQ.
- See `rake -T` for common tasks (`rake check`, `rake format`, `rake test`).

## Release

1. Update `HireFire::VERSION` in `lib/hirefire/version.rb` (prerelease: RubyGems
   form, e.g. `2.0.0.rc1`).
2. If root `Gemfile` or gemspec development dependencies changed, update root `Gemfile.lock` with `bundle install`. Appraisal `gemfiles/*.gemfile.lock` files are gitignored so CI re-resolves each matrix cell to the latest minor/patch on its major.
3. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` (today's date) and add a fresh empty `## [Unreleased]` above it.
4. Commit changes with `git commit`.
5. Create a `git tag` matching the new version (e.g., `v2.0.0` or `v2.0.0.rc1`).
6. Push the new git tag. Continuous Integration will handle the distribution process.
   Prereleases are not installed by default (`gem install` needs `--pre` or a pin).

## License

This gem is licensed under the terms of the MIT license.

[HireFire]: https://hirefire.io/
[Heroku]: https://heroku.com/
