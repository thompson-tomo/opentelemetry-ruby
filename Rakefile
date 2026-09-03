# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require "yaml"

LABELER_FILE = ".github/labeler.yml"
TOYS_FILE    = ".toys/.data/releases.yml"

namespace :each do
  task :bundle_install do
    foreach_gem('bundle install')
  end

  task :bundle_update do
    foreach_gem('bundle update')
  end

  task :test do
    foreach_gem('bundle exec rake test')
  end

  task :yard do
    foreach_gem('bundle exec rake yard')
  end

  desc "Run rubocop in each gem"
  task :rubocop do
    foreach_gem('bundle exec rake rubocop')
  end

  task :default do
    foreach_gem('bundle exec rake')
  end
end

task each: 'each:default'

task default: [:each]

def discover_gems
  Dir.glob("**/opentelemetry-*.gemspec")
     .reject { |path|
       EXCLUDED_DIRS.any? { |d| path.include?("/#{d}/") || path.start_with?("#{d}/") }
     }
     .map { |gemspec|
       { dir: File.dirname(gemspec), name: gemspec }
     }
     .sort_by { |h| h[:dir] }
end

def foreach_gem(cmd)
  discover_gems.each do |gemspec|
    dir  = gem[:dir]
    puts "**** Entering #{dir}"
    Dir.chdir(dir) do
      if defined?(Bundler)
        Bundler.with_clean_env do
          sh(cmd)
        end
      else
        sh(cmd)
      end
    end
  end
end

task :check_labeler_defined do
  labeler = nil
  begin
    labeler = YAML.load_file(LABELER_FILE)
  rescue Errno::ENOENT
    puts "Labeler file missing: #{LABELER_FILE}"
    labeler == {}
  end

  toys_by_name = toys.fetch("gems", []).map { |g| [g["name"], g] }.to_h

  issue_count = 0

  discover_gems.each do |gem|
    parent_dir  = gem[:dir]
    name = gem[:name]

    labeler_key = parent_dir.tr("/", "-")
    expected_glob = "#{parent_dir}/**"

    # --- Labeler key existence ---
    unless labeler == {} || labeler.key?(labeler_key)
      puts "::error:: Missing labeler key: #{labeler_key}"
      issue_count += 1
      next
    end

    # Extract globs for THIS key only
    globs =
      labeler[labeler_key]
        .flat_map { |entry| entry["changed-files"] }
        .compact
        .flat_map { |cf| cf["any-glob-to-any-file"] }
        .compact

    # --- Labeler directory glob ---
    unless labeler == {} || globs.include?(expected_glob)
      puts "::error:: Labeler key #{labeler_key} missing glob #{expected_glob}"
      issue_count += 1
    end

    # --- compose.yml rule ---
    compose_file = File.join(parent_dir, "test", "compose.yml")
    if File.exist?(compose_file)
      unless globs.any? { |glob| glob.start_with?(".docker/infra") }
        puts "::error:: compose.yml found for #{parent_dir}/test, but labeler key #{labeler_key} missing .docker/infra/** glob"
        issue_count += 1
      end
    end
  puts "Issues: #{issue_count}"

  abort if issue_count > 0
end

task :check_releases_defined do
  toys = YAML.load_file(TOYS_FILE)

  toys_by_name = toys.fetch("gems", []).map { |g| [g["name"], g] }.to_h

  issue_count = 0

  discover_gems.each do |gem|
    parent_dir  = gem[:dir]
    name = gem[:name]

    # --- Toys entry existence ---
    toys_entry = toys_by_name[name]
    if toys_entry.nil?
      puts "::error:: Missing toys entry for #{name}"
      issue_count += 1
    else
      # --- Toys name match ---
      if toys_entry['directory'] != parent_dir
        puts "::error:: Toys directory mismatch for #{name}: expected #{parent_dir}, got #{toys_entry['directory']}"
        issue_count += 1
      end
    end
  end

  puts "Issues: #{issue_count}"

  abort if issue_count > 0
end
