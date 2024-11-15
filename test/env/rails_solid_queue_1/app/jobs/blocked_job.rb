class BlockedJob < ActiveJob::Base
  BLOCK_DURATION = 10.seconds
  limits_concurrency to: 1, key: "ratelimit", duration: BLOCK_DURATION

  def perform
  end
end
