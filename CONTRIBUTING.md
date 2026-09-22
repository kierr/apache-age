# Contributing to apache-age

Bug reports and pull requests are welcome on GitHub at
https://github.com/kierr/apache-age.

## Bug reports

Please include:

* Ruby version (`ruby -v`)
* Apache AGE version
* PostgreSQL version
* Minimal reproduction script

## Pull requests

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Write tests for your change
4. Ensure all checks pass: `bundle exec rake ci`
5. Commit with a clear message
6. Open a pull request against `main`

## Development

After checking out the repo:

```bash
bin/setup       # install dependencies
bundle exec rake test   # run tests
bundle exec rake ci     # run all checks (test + lint + typecheck)
```

A PostgreSQL instance with Apache AGE is needed for integration tests.
Use `docker compose up` to start one, then:

```bash
DATABASE_URL=postgres://age_user:age_pass@localhost:5434/age_test bundle exec rake test
```

## Releasing

Releases are automated: push a tag (`vX.Y.Z`) and the release workflow
publishes to RubyGems via OIDC. No manual gem push required.
