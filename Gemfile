# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

gem "debug"
gem "rake"
gem "standardrb"
gem "minitest"
gem "webmock"
gem "mocha"
gem "timecop"
gem "yard"
gem "rack"
gem "simplecov", require: false

gem "base64"

# addressable (via webmock) allows public_suffix < 8, but public_suffix 7+ needs
# Ruby >= 3.2. Pin for the Ruby 3.1 CI matrix cells.
gem "public_suffix", "< 7"
