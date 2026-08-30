appraise "default" do
  # n/a
end

appraise "bunny_2" do
  gem "bunny", "~> 2"
end

appraise "bunny_3" do
  gem "bunny", "~> 3"
end

appraise "delayed_job_active_record_4" do
  gem "pg"
  gem "rails", "~> 8"
  gem "delayed_job_active_record", "~> 4"
end

appraise "delayed_job_mongoid_3" do
  gem "rails", "~> 8"
  gem "mongoid", "~> 9"
  gem "delayed_job_mongoid", "~> 3"
  gem "ostruct"
end

appraise "good_job_3" do
  gem "pg"
  gem "rails", "~> 8"
  gem "good_job", "~> 3", require: false
end

appraise "good_job_4" do
  gem "pg"
  gem "rails", "~> 8"
  gem "good_job", "~> 4", require: false
end

appraise "queue_classic_4" do
  gem "pg"
  gem "rails", "~> 8"
  gem "queue_classic", "~> 4"
end

appraise "que_1" do
  gem "pg"
  gem "rails", "~> 8"
  gem "que", "~> 1", require: false
end

appraise "que_2" do
  gem "pg"
  gem "rails", "~> 8"
  gem "que", "~> 2", require: false
end

appraise "rack_2" do
  gem "rack", "~> 2"
end

appraise "rack_3" do
  gem "rack", "~> 3"
end

appraise "resque_2" do
  gem "resque", "~> 2"
  # 1.8.x supports resque < 3 and Ruby 3.1. 1.9+ needs Ruby >= 3.2 and resque < 4.
  gem "resque-retry", "~> 1.8.0"
  gem "resque-scheduler", "~> 4"
end

appraise "resque_3" do
  gem "resque", "~> 3"
  # 1.9+ is the first line that allows resque 3. It requires Ruby >= 3.2 (CI excludes 3.1).
  gem "resque-retry", "~> 1.9"
  gem "resque-scheduler", "~> 5"
end

appraise "sidekiq_7" do
  gem "sidekiq", "~> 7"
end

appraise "sidekiq_8" do
  gem "sidekiq", "~> 8"
end

appraise "solid_queue_1" do
  gem "pg"
  gem "rails", "~> 8"
  gem "solid_queue", "~> 1", require: false
end

appraise "rails_7" do
  gem "rails", "~> 7"
end

appraise "rails_8" do
  gem "rails", "~> 8"
end

appraise "sinatra_3" do
  gem "sinatra", "~> 3", require: false
  gem "ostruct"
end

appraise "sinatra_4" do
  gem "sinatra", "~> 4", require: false
end

appraise "hanami_2" do
  gem "hanami-router", "~> 2", require: false
end

appraise "hanami_3" do
  gem "hanami-router", "~> 3", require: false
end
