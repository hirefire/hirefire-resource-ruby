## HireFire: Advanced autoscaling for Heroku-hosted applications

Since 2011, over 1,000 companies have trusted [HireFire] to autoscale more than 5,000 applications hosted on [Heroku], with over 10,000 web and worker dynos.

## Guides & Documentation

You can find the integration instructions in-app on [HireFire] when you are setting up your Dyno Manager (Autoscaler).

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
