## HireFire Integration Library for Ruby Applications

This library integrates Ruby applications with HireFire's Dyno Managers (Heroku Dyno Autoscalers). Instructions specific to supported web frameworks and worker libraries are provided during the setup process.

**Supported runtimes:** Ruby 3.2+

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
- Resque 2+
- Que 1+
- QC 4+
- Bunny 2+

The test suite runs against these minimum versions and the current latest release of each runtime and library. Older versions may still work, but are not officially supported.

---

Since 2011, over 1,500 companies have trusted [HireFire] to autoscale more than 5,000 applications hosted on [Heroku], managing over 10,000 web and worker dynos.

HireFire is distinguished by its support for both web and worker dynos, extending autoscaling capabilities to Standard-tier dynos. It provides fine-grained control over scaling behavior and improves scaling accuracy by monitoring more reliable metrics at the application level. These metrics include request queue time (web), job queue latency (worker), and job queue size (worker), which contribute to making more effective scaling decisions.

For more information, visit the [home page][HireFire].

---

## Development

Requires [Docker](https://www.docker.com/) — PostgreSQL, MongoDB, Redis, and RabbitMQ for the macro tests run in containers. `bin/services up` starts them on Docker-assigned free host ports recorded in a git-ignored `.env` (read by the test suite); `bin/services down` stops them and removes `.env`.

- Run `bin/setup` to prepare the environment.
- Run `bin/services up` / `bin/services down` to start / stop the database containers.
- See `rake -T` for common tasks.

## Release

1. Update the `HireFire::VERSION` constant.
2. Update Gemfile locks with `bundle` and `bundle exec appraisal`.
3. Ensure that `CHANGELOG.md` is up-to-date.
4. Commit changes with `git commit`.
5. Create a `git tag` matching the new version (e.g., `v1.0.0`).
6. Push the new git tag. Continuous Integration will handle the distribution process.

## License

This gem is licensed under the terms of the MIT license.

[HireFire]: https://hirefire.io/
[Heroku]: https://heroku.com/
