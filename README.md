## HireFire: Advanced Autoscaling for Heroku-hosted Applications

[HireFire] is the oldest and a leading autoscaling service for applications hosted on [Heroku]. Since 2011, we've assisted more than 1,000 companies in autoscaling upwards of 5,000 applications, involving over 10,000 dynos.

This gem streamlines the integration of HireFire with Ruby applications running on Heroku, offering companies substantial cost savings while maintaining optimal performance.

---

### Supported Ruby Versions:

|    | MRI Ruby |
|----|----------|
| ✅ | 3.2      |
| ✅ | 3.1      |
| ✅ | 3.0      |
| ✅ | 2.7      |

---

### Supported Ruby Web Frameworks:

HireFire comes with Rack middleware integration, making it compatible with a broad range of Rack-based applications, including:

|    | Ruby Web Framework |
|----|--------------------|
| ✅ | Rack               |
| ✅ | Rails              |
| ✅ | Sinatra            |
| ✅ | Hanami             |

---

### Supported Ruby Worker Libraries:

Some libraries lack the requisite structure to measure latency. If your preferred library isn't listed, or if you need further support, please contact us.

| Ruby Worker Library | Job Queue Latency | Job Queue Size |
|---------------------|:-----------------:|:--------------:|
| Bunny               | ❌                | ✅             |
| Delayed Job         | ✅                | ✅             |
| Good Job            | ✅                | ✅             |
| Que                 | ✅                | ✅             |
| Queue Classic (QC)  | ✅                | ✅             |
| Resque              | ❌                | ✅             |
| Sidekiq             | ✅                | ✅             |

---

### Integration Demonstration

To easily integrate HireFire with an existing Ruby application (i.e. Rails and Sidekiq):

1. Add the gem to your `Gemfile`:

```ruby
gem "hirefire-resource"
```

2. Configure HireFire in `config/initializers/hirefire.rb`:

```ruby
HireFire.configure do |config|
  # To collect Request Queue Time metrics for autoscaling `web` dynos:
  config.dyno(:web)
  # To collect Job Queue Latency metrics for autoscaling `worker` dynos
  config.dyno(:worker) { HireFire::Macro::Sidekiq.job_queue_latency(:default) }
end
```

After completing these steps, deploy your application to Heroku. Then, [sign into HireFire] to complete your autoscaling setup by adding the web and worker dyno managers.

---

## Development

### Setup

Run `bin/setup` to prepare the environment by installing dependencies.

### Tasks

Use `bundle exec rake` to perform common tasks (i.e. format, test). See `bundle exec rake -T`.

### Installation

Install this gem on your local machine using `bundle exec rake install`.

### Releases

1. Bump the `HireFire::VERSION` constant.
2. Update `CHANGELOG.md` for the bumped version.
3. Commit your changes with `git commit`.
4. Create a new git tag matching the bumped version (e.g., `v1.0.0`) with `git tag`.
5. Push the new tag. GitHub Actions will handle the release process from there.

---

### Questions?

Feel free to [contact us] for support and inquiries.

---

### License

`hirefire-resource` is licensed under the MIT license. See LICENSE.

[HireFire]: https://www.hirefire.io/
[Heroku]: https://www.heroku.com/
[sign into HireFire]: https://manager.hirefire.io/login
[contact us]: mailto:support@hirefire.io
