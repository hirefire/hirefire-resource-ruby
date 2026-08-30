# frozen_string_literal: true

require "test_helper"

class HireFire::ReadmeSupportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SIZE_ONLY = %w[resque bunny].freeze

  def test_runtime_floor_matches_gemspec
    gemspec = File.read(File.join(ROOT, "hirefire-resource.gemspec"))
    constraint = gemspec[/\.required_ruby_version\s*=\s*"([^"]+)"/, 1]
    major_minor = constraint[/\d+\.\d+/]
    assert_equal "Ruby #{major_minor}+", runtime_bullet
  end

  def test_every_appraisal_family_is_in_the_readme_and_the_readme_has_no_extras
    floors = appraisal_floors
    bullets = support_bullets
    used = []
    floors.each do |family, majors|
      bullet = bullets.find { |line| matches_family?(family, line) }
      assert bullet, "README missing a line for appraisal family #{family} (#{majors.min}+)"
      used << bullet
      assert_includes bullet, "#{majors.min}+"
      if SIZE_ONLY.include?(family)
        assert_includes bullet, "size only, no job queue latency"
      else
        refute_includes bullet, "size only"
      end
    end
    assert_equal bullets.sort, used.uniq.sort
  end

  private

  def runtime_bullet
    section_bullets("Supported runtimes").fetch(0)
  end

  def support_bullets
    section_bullets("Supported web frameworks") +
      section_bullets("Supported worker libraries")
  end

  def section_bullets(heading)
    readme = File.read(File.join(ROOT, "README.md"))
    chunk = readme[/^\*\*#{Regexp.escape(heading)}:\*\*\n\n((?:- .+\n)+)/, 1]
    raise "missing README section #{heading}" unless chunk

    chunk.lines.map { |line| line.sub(/\A- /, "").strip }
  end

  def appraisal_floors
    floors = Hash.new { |h, k| h[k] = [] }
    File.read(File.join(ROOT, "Appraisals")).scan(/appraise\s+"([^"]+)"/).flatten.each do |name|
      next if name == "default"

      family, major = name.match(/\A(.+)_(\d+)\z/).captures
      floors[family] << major.to_i
    end
    floors
  end

  def matches_family?(family, line)
    bullet = bullet_token(line)
    parts = family.split("_")
    (1..parts.size).any? { |n| normalize(parts[0, n].join("_")) == bullet }
  end

  def bullet_token(line)
    stem = line.sub(/\s+\(.*\)\z/, "")
    normalize(stem[/\A(.+?)\s+\d/, 1] || stem)
  end

  def normalize(value)
    value.downcase.gsub(/[^a-z0-9]+/, "")
  end
end
