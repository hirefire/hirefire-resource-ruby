# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

gem "debug"
gem "rake"
gem "standardrb"
# parallel 2.x requires Ruby >= 3.3, but the CI matrix still tests Ruby 3.2.
# It's a transitive lint dependency (standardrb -> rubocop), so 1.x suffices.
gem "parallel", "< 2"
gem "minitest"
gem "webmock"
gem "mocha"
gem "timecop"
gem "yard"
gem "rack"
gem "webrick"
gem "simplecov", require: false

gem "base64"
