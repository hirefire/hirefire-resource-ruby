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

  def test_resolves_fir_pod_names_with_mixed_case_suffixes
    ENV["DYNO"] = "web-12A34B56D-E78F9"
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

  def test_strips_whitespace_from_identity_env
    ENV["HIREFIRE_SERVICE_NAME"] = "  clock  \n"
    assert_equal "clock", HireFire::Identity.resolve

    ENV["HIREFIRE_SERVICE_NAME"] = nil
    ENV["DYNO"] = "  worker.1  "
    assert_equal "worker", HireFire::Identity.resolve

    ENV["DYNO"] = nil
    ENV["RENDER_SERVICE_NAME"] = "\tapi\t"
    assert_equal "api", HireFire::Identity.resolve
  end

  def test_whitespace_only_identity_env_is_absent
    ENV["HIREFIRE_SERVICE_NAME"] = "   "
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

  def test_heroku_dyno_takes_precedence_over_render_service_name
    ENV["DYNO"] = "worker.1"
    ENV["RENDER_SERVICE_NAME"] = "api"
    assert_equal "worker", HireFire::Identity.resolve
  end

  def test_dyno_name_without_a_suffix_is_returned_as_is
    ENV["DYNO"] = "web"
    assert_equal "web", HireFire::Identity.resolve
  end

  def test_dyno_name_with_a_single_trailing_segment_is_preserved
    ENV["DYNO"] = "worker-abc123"
    assert_equal "worker-abc123", HireFire::Identity.resolve
  end

  def test_dyno_that_strips_to_empty_is_unresolved
    ENV["DYNO"] = ".1"
    assert_nil HireFire::Identity.resolve

    ENV["DYNO"] = "-ab-cd"
    assert_nil HireFire::Identity.resolve
  end

  def test_platform_http_role_heroku_cedar_web
    ENV["DYNO"] = "web.1"
    assert HireFire::Identity.heroku_web_process?
    assert HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_heroku_fir_web
    ENV["DYNO"] = "web-5fb9c979-lft2l"
    assert HireFire::Identity.heroku_web_process?
    assert HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_heroku_worker_is_not_web
    %w[worker.1 worker.42].each do |dyno|
      ENV["DYNO"] = dyno
      refute HireFire::Identity.heroku_web_process?, dyno
      refute HireFire::Identity.platform_http_role?, dyno
    end
  end

  def test_platform_http_role_uses_dyno_not_explicit_service_name
    ENV["HIREFIRE_SERVICE_NAME"] = "web"
    ENV["DYNO"] = "worker.1"
    refute HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_render_web_service_type
    ENV["RENDER_SERVICE_NAME"] = "api"
    ENV["RENDER_SERVICE_TYPE"] = "web"
    assert HireFire::Identity.render_web_service?
    assert HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_is_case_insensitive
    ENV["DYNO"] = "Web.1"
    assert HireFire::Identity.platform_http_role?

    ENV["DYNO"] = nil
    ENV["RENDER_SERVICE_NAME"] = "api"
    ENV["RENDER_SERVICE_TYPE"] = "Web"
    assert HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_render_worker_type
    ENV["RENDER_SERVICE_NAME"] = "worker"
    ENV["RENDER_SERVICE_TYPE"] = "worker"
    refute HireFire::Identity.render_web_service?
    refute HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_render_pserv_is_not_web_role
    ENV["RENDER_SERVICE_TYPE"] = "pserv"
    refute HireFire::Identity.platform_http_role?
  end

  def test_platform_http_role_false_with_no_platform_env
    refute HireFire::Identity.platform_http_role?
    refute HireFire::Identity.heroku_web_process?
    refute HireFire::Identity.render_web_service?
  end

  def test_heroku_web_process_rejects_names_that_only_start_with_web
    %w[webworker.1 webbing.1 web_service.1].each do |dyno|
      ENV["DYNO"] = dyno
      refute HireFire::Identity.heroku_web_process?, dyno
      refute HireFire::Identity.platform_http_role?, dyno
    end
  end

  def test_heroku_web_process_rejects_fir_worker
    ENV["DYNO"] = "worker-12a34b56d-e78f9"
    refute HireFire::Identity.heroku_web_process?
    refute HireFire::Identity.platform_http_role?
  end

  def test_heroku_conflict_false_when_only_dyno_present
    ENV["DYNO"] = "web.1"
    refute HireFire::Identity.heroku_conflict?
  end

  def test_render_service_type_blank_is_not_web_role
    ENV["RENDER_SERVICE_NAME"] = "api"
    ENV["RENDER_SERVICE_TYPE"] = "   "
    refute HireFire::Identity.render_web_service?
    refute HireFire::Identity.platform_http_role?
  end
end
