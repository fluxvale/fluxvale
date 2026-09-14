#!/usr/bin/env bash
# Skills frontmatter lint: every SKILL.md under .agents/ must carry
# parseable, spec-shaped frontmatter. A skill whose frontmatter doesn't
# parse is silently unloadable in every harness — pi reports it under
# "Skill conflicts" and never offers it to agents; Claude Code et al.
# behave the same. #52 shipped exactly that (an unquoted description
# containing ": " — valid-looking, rejected by every strict YAML parser)
# through a green pipeline because nothing looked (#53 fixed the
# instance, #54; this guard closes the class — finding 1 of #54's
# fresh-eyes review).
#
# Hard-fail classes:
#   unloadable — no --- delimiters, YAML parse error, frontmatter not a
#                mapping, missing/empty/non-string name or description
#   spec shape — name not ^[a-z0-9]+(-[a-z0-9]+)*$ or > 64 chars;
#                description > 1024 chars (Agent Skills spec, as
#                enforced-with-warning by pi and hard by other harnesses)
#
# Parser: ruby stdlib psych — a real YAML parser (regexes cannot guard
# ": " inside-quotes-vs-outside), verified to reject the #52 text.
# Preinstalled on ubuntu-latest and locally; no new mise.toml entries.
set -euo pipefail
cd "$(dirname "$0")/.."

exec ruby <<'RUBY'
require "yaml"

NAME_RE = /\A[a-z0-9]+(-[a-z0-9]+)*\z/.freeze

skills = Dir.glob(".agents/**/SKILL.md").sort
if skills.empty?
  warn "::error file=.agents/skills::no SKILL.md found under .agents/ — skills were removed or this glob is stale"
  exit 1
end

failures = 0
skills.each do |path|
  errors = []
  begin
    text = File.read(path)
    fm = text.match(/\A---\r?\n(.*?)\r?\n---/m)
    errors << "frontmatter block (--- … ---) not found at top of file" unless fm
    if fm
      begin
        doc = YAML.safe_load(fm[1], permitted_classes: [], aliases: false)
      rescue Psych::SyntaxError => e
        errors << "YAML parse error: #{e.message}"
        doc = nil
      end
      if fm && doc && !doc.is_a?(Hash)
        errors << "frontmatter parsed to #{doc.class}, expected a mapping"
      end
      if doc.is_a?(Hash)
        name = doc["name"]
        desc = doc["description"]
        errors << "`name` missing/empty" unless name.is_a?(String) && !name.empty?
        if name.is_a?(String)
          errors << "`name` violates ^[a-z0-9]+(-[a-z0-9]+)*$: #{name.inspect}" unless name.match?(NAME_RE)
          errors << "`name` exceeds 64 chars (#{name.length})" if name.length > 64
        end
        errors << "`description` missing/empty — harnesses drop the skill" unless desc.is_a?(String) && !desc.empty?
        errors << "`description` exceeds 1024 chars (#{desc.length})" if desc.is_a?(String) && desc.length > 1024
      end
    end
  rescue StandardError => e
    errors << "unexpected: #{e.message}"
  end
  errors.each { |msg| warn "::error file=#{path}::#{msg.gsub("\n", " ")}" }
  failures += 1 unless errors.empty?
end

if failures.zero?
  puts "Skills frontmatter consistent (#{skills.size} SKILL.md)"
else
  warn "#{failures} of #{skills.size} SKILL.md failed frontmatter validation"
  exit 1
end
RUBY
