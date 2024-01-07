## HireFire: Advanced Autoscalers for Heroku

Since 2011, over 1,000 companies have trusted [HireFire] to autoscale more than 5,000 applications hosted on [Heroku], managing over 10,000 web and worker dynos.

HireFire is distinguished by its support for both web and worker dynos, unlike Heroku, which focuses solely on web dynos. Additionally, HireFire extends autoscaling capabilities to Standard-tier dynos, whereas Heroku is limited to the more expensive Performance-tier and above. Our platform offers fine-grained control over scaling behavior and improved reliability through the utilization of superior metrics for making more effective scaling decisions.

For more information, visit our [home page][HireFire].

## Instructions

You can find the integration instructions on [HireFire] when you are setting up your Dyno Manager (Autoscaler).

## Development

- Run `bin/setup` to prepare the environment.
- See `rake -T` for common tasks.

## Release

1. Update the `HireFire::VERSION` constant.
2. Ensure that `CHANGELOG.md` is up-to-date.
3. Commit changes with `git commit`.
4. Create a `git tag` matching the new version (e.g., `v1.0.0`).
5. Push the new git tag. Continuous Integration will handle the distribution process.

## License

This gem is licensed under the terms of the MIT license.

[HireFire]: https://www.hirefire.io/
[Heroku]: https://www.heroku.com/
