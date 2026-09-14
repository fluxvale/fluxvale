#!/usr/bin/env bash
# Skills frontmatter lint: markdown files under .agents/ that declare
# skill frontmatter must parse and match the Agent Skills spec shape —
# a skill whose frontmatter doesn't parse is silently unloadable in
# every harness (pi reports it under "Skill conflicts" and never offers
# it to agents). #52 shipped exactly that (an unquoted description
# containing ": " — valid-looking, rejected by every strict YAML parser)
# through a green pipeline because nothing looked (#53 fixed the
# instance, #54; this guard closes the class — finding 1 of #54's
# fresh-eyes review).
#
# Scope: every SKILL.md under .agents/ (always a skill), plus any other
# .md that DECLARES frontmatter (leading --- line) — pi's discovery
# surface (pi skills doc: nested .md in grouping folders is discovered
# when it declares frontmatter). Prose .md without frontmatter is
# ignored by harnesses and by this lint. This is a validated SUPERSET:
# harness discovery differs at the margins (pi ignores root .md in
# skills/), but a file that declares skill frontmatter must parse
# everywhere — a false positive there beats replicating per-harness
# discovery rules in bash.
#
# Hard-fail classes:
#   unloadable — no --- delimiters, YAML parse error, empty/non-mapping
#                frontmatter, missing/empty/non-string name or
#                description
#   spec shape — name not ^[a-z0-9]+(-[a-z0-9]+)*$ or > 64 chars;
#                description > 1024 chars
#
# Parser: ruby stdlib psych — a real YAML parser (regexes cannot guard
# ": " inside-quotes-vs-outside), verified to reject the #52 text.
# Known margin: psych is YAML 1.1, harness parsers (eemeli/yaml et al.)
# are 1.2 core — psych coerces on/yes/1:2/017 style scalars where 1.2
# reads strings. The lint treats a coerced (non-String) name/description
# as an error with a quote-the-value hint: unambiguous quoting is valid
# under both dialects, so the lint never rejects a file 1.2 loaders
# would load once it's quoted.
set -euo pipefail
cd "$(dirname "$0")/.."

exec ruby <<'RUBY'
require "yaml"

NAME_RE = /\A[a-z0-9]+(-[a-z0-9]+)*\z/.freeze

markdown = Dir.glob(".agents/**/*.md").sort
skills = markdown.select { |p| File.basename(p) == "SKILL.md" }
declared = markdown.reject { |p| File.basename(p) == "SKILL.md" }
                  .select { |p| File.read(p).match?(/\A\uFEFF?---\r?\n/) }

if skills.empty?
  warn "::error file=.agents/skills::no SKILL.md found under .agents/ — skills were removed or this glob is stale"
  exit 1
end

failures = 0
(skills + declared).each do |path|
  errors = []
  begin
    text = File.read(path)
    fm = text.match(/\A\uFEFF?---\r?\n(.*?)\r?\n---/m)
    if fm
      begin
        doc = YAML.safe_load(fm[1], permitted_classes: [], aliases: false)
      rescue Psych::SyntaxError => e
        errors << "YAML parse error: #{e.message}"
        doc = nil
      end
      unless doc.is_a?(Hash)
        errors << "frontmatter is empty or not a mapping (#{doc.inspect})"
      end
      if doc.is_a?(Hash)
        name = doc["name"]
        desc = doc["description"]
        unless name.is_a?(String) && !name.strip.empty?
          errors << "`name` missing/empty or coerced by YAML-1.1 (on/yes/017 style) — quote the value"
        end
        if name.is_a?(String)
          errors << "`name` violates ^[a-z0-9]+(-[a-z0-9]+)*$: #{name.inspect}" unless name.match?(NAME_RE)
          errors << "`name` exceeds 64 chars (#{name.length})" if name.length > 64
        end
        unless desc.is_a?(String) && !desc.strip.empty?
          errors << "`description` missing/empty or coerced — quote the value; harnesses drop the skill"
        end
        errors << "`description` exceeds 1024 chars (#{desc.length})" if desc.is_a?(String) && desc.length > 1024
      end
    else
      errors << "frontmatter block (--- … ---) not found at top of file"
    end
  rescue StandardError => e
    errors << "unexpected: #{e.message}"
  end
  errors.each { |msg| warn "::error file=#{path}::#{msg.gsub("\n", " ")}" }
  failures += 1 unless errors.empty?
end

if failures.zero?
  puts "Skills frontmatter consistent (#{skills.size} SKILL.md, #{declared.size} declared .md)"
else
  warn "#{failures} of #{skills.size + declared.size} files failed frontmatter validation"
  exit 1
end
RUBY
