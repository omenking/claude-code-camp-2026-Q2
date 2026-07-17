#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-applies the local bubbletea native-extension fix to the *installed* gem and
# rebuilds the .so. The patch makes program_poll_event() keep a pending-bytes
# buffer so a single read() that returns several bytes (pastes / fast typing on
# WSL2 ptys) is no longer truncated to its first key event.
#
# WHY THIS EXISTS: bubbletea ships as a precompiled platform gem, so the patch
# lives outside the repo at ~/.rvm/.../gems/bubbletea-*/ and is LOST whenever the
# gem is reinstalled (e.g. `bundle install` re-resolving the native gem). The
# authoritative patched sources are versioned here in patches/bubbletea/; this
# script copies them in and rebuilds, so the fix is reproducible with one command
# and survives reinstalls.
#
# No Go toolchain is required: it reuses the prebuilt libbubbletea.a that ships
# inside the gem and only recompiles the C glue (program.c / extension.c).
#
# Usage — this patch is self-contained in this directory. From anywhere inside
# the 11_tui project (bundler finds the Gemfile up the tree):
#     bundle exec ruby patches/bubbletea/patch_bubbletea.rb
# or run it from this directory directly:
#     cd patches/bubbletea && bundle exec ruby patch_bubbletea.rb
#
# To revert to the pristine upstream gem: `gem pristine bubbletea`
#
# See docs/tui_keyboard_input_bug.md and docs/tui_typing_latency_plan.md.

require "rbconfig"
require "fileutils"

EXPECTED_VERSION = "0.1.4"
PATCH_DIR  = __dir__   # patched sources live alongside this script
PATCHED    = %w[program.c extension.h].freeze

def die(msg)
  warn "patch_bubbletea: #{msg}"
  exit 1
end

def sh(cmd, chdir:)
  puts "  $ #{cmd}"
  ok = system(cmd, chdir: chdir)
  die "command failed (#{cmd})" unless ok
end

# 1. Locate the installed gem (the bundled one when run under `bundle exec`).
spec =
  begin
    Gem::Specification.find_by_name("bubbletea")
  rescue Gem::MissingSpecError
    die "bubbletea gem not found — run `bundle install` first."
  end

gem_dir = spec.gem_dir
ext_dir = File.join(gem_dir, "ext", "bubbletea")
abi     = RUBY_VERSION.split(".").first(2).join(".")        # e.g. "4.0"
lib_so  = File.join(gem_dir, "lib", "bubbletea", abi, "bubbletea.so")

puts "bubbletea #{spec.version} at #{gem_dir}"
puts "ruby ABI #{abi} -> #{lib_so}"

if spec.version.to_s != EXPECTED_VERSION
  warn "WARNING: expected bubbletea #{EXPECTED_VERSION} but found #{spec.version}."
  warn "         The stored patch may not apply cleanly; review patches/bubbletea/ "
  warn "         before trusting the result."
end

die "extension sources not found at #{ext_dir}" unless File.directory?(ext_dir)
die "patched sources missing in #{PATCH_DIR}"    unless PATCHED.all? { |f| File.exist?(File.join(PATCH_DIR, f)) }

# 2. Copy the versioned patched sources over the freshly-installed originals.
puts "Applying patched sources:"
PATCHED.each do |f|
  src = File.join(PATCH_DIR, f)
  dst = File.join(ext_dir, f)
  FileUtils.cp(src, dst)
  puts "  #{f}"
end

# 3. Rebuild (reuses the gem's prebuilt libbubbletea.a — no Go needed) and strip.
puts "Rebuilding extension:"
sh("make clean 2>/dev/null; ruby extconf.rb", chdir: ext_dir)
sh("make", chdir: ext_dir)
sh("strip --strip-debug bubbletea.so", chdir: ext_dir)

# 4. Install the stripped .so into the gem's lib for the current ABI.
built = File.join(ext_dir, "bubbletea.so")
die "build did not produce bubbletea.so" unless File.exist?(built)
FileUtils.mkdir_p(File.dirname(lib_so))
FileUtils.cp(built, lib_so)
puts "Installed #{File.size(lib_so)} bytes -> #{lib_so}"

# 5. Sanity-check: the .so loads and exposes poll_event.
load_ok = system(RbConfig.ruby, "-e",
                 'require "bubbletea"; exit(Bubbletea::Program.instance_methods.include?(:poll_event) ? 0 : 1)')
die "rebuilt .so failed to load / poll_event missing" unless load_ok

puts "OK: bubbletea input patch applied and verified."
puts "    (run the pty burst harness to confirm multi-byte input drains fully)"
