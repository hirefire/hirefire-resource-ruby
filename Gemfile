# frozen_string_literal: true

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

gemspec

gem "debug"
gem "rake"
gem "standardrb"
gem "webmock"
gem "mocha"
gem "timecop"
gem "yard"
gem "rack"
gem "simplecov", require: false

gem "base64"

# Dev-tool pins for the Ruby 3.1 CI matrix. Root Gemfile.lock is shared across
# all matrix Rubies. These upper bounds keep resolution on gems that still
# declare support for 3.1 (several majors now require >= 3.2).
gem "minitest", "< 6"
gem "public_suffix", "< 7" # addressable allows < 8; 7+ needs Ruby >= 3.2
gem "erb", "< 5" # rdoc pulls erb; 5+ needs Ruby >= 3.2
