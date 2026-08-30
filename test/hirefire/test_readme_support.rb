# frozen_string_literal: true

require "test_helper"

class HireFire::ReadmeSupportTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SIZE_ONLY = %w[resque bunny].freeze

  def test_runtime_floor_matches_gemspec
    gemspec = File.read(File.join(ROOT, "hirefire-resource.gemspec"))
    constraint = gemspec[/\.required_ruby_version\s*=\s*"([^"]+)"/, 1]
    major_minor = constraint[/\d+\.\d+/]
    ci_min = workflow_ruby_versions.min_by { |v| Gem::Version.new(v) }
    assert_equal major_minor, ci_min
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

  def test_raised_ruby_floors_are_stated_in_the_readme
    note = support_note
    ruby_versions = workflow_ruby_versions
    global_min = ruby_versions.min_by { |v| Gem::Version.new(v) }
    rails8_workers = rails8_pinned_appraisals
    excludes = workflow_excludes

    appraisal_names.each do |appraisal|
      remaining = ruby_versions - excludes.fetch(appraisal, [])
      min_ruby = remaining.min_by { |v| Gem::Version.new(v) }
      next if min_ruby == global_min

      family, major = appraisal.match(/\A(.+)_(\d+)\z/).captures
      label = family_label(family)
      if rails8_workers.include?(appraisal)
        assert_includes note, label
        assert_includes note, "Ruby #{min_ruby}+"
        next
      end

      assert_match(
        /#{Regexp.escape(label)} #{major}.*Ruby #{Regexp.escape(min_ruby)}\+/,
        note,
        "README should state #{label} #{major} requires Ruby #{min_ruby}+"
      )
    end
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

  def support_note
    note = File.read(File.join(ROOT, "README.md"))[
      /\*\*Supported worker libraries:\*\*\n\n(?:- .+\n)+\n(.+)/, 1
    ]
    raise "missing README support note after worker libraries" if note.nil? || note.strip.empty?

    note
  end

  def appraisal_names
    File.read(File.join(ROOT, "Appraisals")).scan(/appraise\s+"([^"]+)"/).flatten - ["default"]
  end

  def appraisal_floors
    floors = Hash.new { |h, k| h[k] = [] }
    appraisal_names.each do |name|
      family, major = name.match(/\A(.+)_(\d+)\z/).captures
      floors[family] << major.to_i
    end
    floors
  end

  def workflow_source
    File.read(File.join(ROOT, ".github/workflows/main.yml"))
  end

  def workflow_ruby_versions
    block = workflow_source[/ruby-version:\n((?:          - "[^"]+"\n)+)/, 1]
    raise "missing ruby-version matrix" unless block

    block.scan(/"([^"]+)"/).flatten
  end

  def workflow_excludes
    workflow_source.scan(/- ruby-version: "([^"]+)"\n            appraisal: (\S+)/)
      .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(ruby, appraisal), acc|
        acc[appraisal] << ruby
      end
  end

  def rails8_pinned_appraisals
    File.read(File.join(ROOT, "Appraisals"))
      .scan(/appraise\s+"([^"]+)" do\n(.*?)end/m)
      .filter_map do |name, body|
        next if name == "default" || name.start_with?("rails_")

        name if body.match?(/gem "rails", "~> 8"/)
      end
  end

  def family_label(family)
    bullet = support_bullets.find { |line| matches_family?(family, line) }
    raise "README missing a line for #{family}" unless bullet

    stem = bullet.sub(/\s+\(.*\)\z/, "")
    stem[/\A(.+?)\s+\d/, 1] || stem
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
