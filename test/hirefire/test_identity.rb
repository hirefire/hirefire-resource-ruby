# frozen_string_literal: true

require "test_helper"

class HireFire::IdentityTest < Minitest::Test
  def test_resolves_to_nil_when_nothing_is_set
    assert_nil HireFire::Identity.resolve
  end

  def test_explicit_service_name_wins
    ENV["HIREFIRE_SERVICE_NAME"] = "clock"
    ENV["DYNO"] = "web.1"
    ENV["RENDER_SERVICE_NAME"] = "api"
    assert_equal "clock", HireFire::Identity.resolve
  end

  def test_falls_back_to_heroku_dyno_prefix
    ENV["DYNO"] = "worker.42"
    assert_equal "worker", HireFire::Identity.resolve
  end

  def test_resolves_fir_pod_names
    ENV["DYNO"] = "web-5fb9c979-lft2l"
    assert_equal "web", HireFire::Identity.resolve
  end

  def test_resolves_fir_pod_names_with_underscores
    ENV["DYNO"] = "worker_latency-6d7f788ddb-cdct6"
    assert_equal "worker_latency", HireFire::Identity.resolve
  end

  def test_fir_pod_name_preserves_dashes_inside_the_process_name
    ENV["DYNO"] = "my-worker-5fb9c979-lft2l"
    assert_equal "my-worker", HireFire::Identity.resolve
  end

  def test_falls_back_to_render_service_name
    ENV["RENDER_SERVICE_NAME"] = "background-worker"
    assert_equal "background-worker", HireFire::Identity.resolve
  end

  def test_blank_values_are_ignored
    ENV["HIREFIRE_SERVICE_NAME"] = ""
    ENV["DYNO"] = "web.1"
    assert_equal "web", HireFire::Identity.resolve
  end

  def test_heroku_conflict_when_explicit_disagrees_with_dyno_prefix
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    ENV["DYNO"] = "worker.1"
    assert HireFire::Identity.heroku_conflict?
  end

  def test_no_heroku_conflict_when_they_agree
    ENV["HIREFIRE_SERVICE_NAME"] = "worker"
    ENV["DYNO"] = "worker.1"
    refute HireFire::Identity.heroku_conflict?
  end

  def test_no_heroku_conflict_without_dyno
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    refute HireFire::Identity.heroku_conflict?
  end

  def test_no_heroku_conflict_when_names_differ_only_in_case
    ENV["HIREFIRE_SERVICE_NAME"] = "Worker"
    ENV["DYNO"] = "worker.1"
    refute HireFire::Identity.heroku_conflict?
  end
end
