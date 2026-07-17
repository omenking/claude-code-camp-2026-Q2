# Floating artifact: `~/.boukensharc`

## What makes it "floating"

Step 9 built real functionality: a YAML `~/.boukensharc` with `boukensha_path:`
and `boukensha_dir:` keys, plus explicit backward compatibility for the
older bare-string format. That's a deliberate feature with a migration path
already thought through.

Step 10's `lib/boukensha_loader.rb` was rewritten for the MCP tool-library
refactor, and in that rewrite the YAML/`boukensha_dir` support **wasn't
carried forward** — not removed on purpose, just not reimplemented. The
capability is "floating": it exists in step 9's code, has no home in step
10 or any step after it, and nothing marks it as intentionally dropped
versus accidentally lost. Each step directory is a standalone snapshot, so
there's no diff or changelog forcing someone to notice a prior step's logic
didn't make it into the next one.

`~/.boukensharc` living in `$HOME` is just what makes the gap *visible* —
a dev machine that ran step 9 has an rc file in the format step 9 taught,
and step 10's loader was never built to understand it. The bug isn't about
the file's location; it's that step 10 doesn't contain logic step 9 already
proved out.

## The two incompatible formats

### Step 9 (`09_global_executable/lib/boukensha_loader.rb`) — YAML mapping

Introduced `boukensha_dir:` alongside `boukensha_path:`, parsed as YAML:

```yaml
boukensha_path: ~/Sites/boukensha/09_global_executable
boukensha_dir: ~/projects/mybot/.boukensha
```

`load_rc` calls `YAML.safe_load`, and explicitly keeps backward compatibility
for a bare string (the pre-step-9 format):

```ruby
case parsed
when Hash   then parsed
when String then { "boukensha_path" => parsed }   # old format
when nil    then {}
end
```

### Step 10 (`10_standard_tool_library/lib/boukensha_loader.rb`) — bare path string

Step 10's loader was rewritten and **dropped YAML parsing entirely**. It
expects the file to contain nothing but a single path:

```ruby
rc = File.expand_path("~/.boukensharc")
if File.exist?(rc)
  dir = File.read(rc).strip
  ...
```

There is no `boukensha_dir` concept in this rc file anymore — config-dir
selection moved to the `BOUKENSHA_DIR` env var only. Critically, there is
also no format detection: `File.read(rc).strip` happily swallows a
multi-line YAML file as if it were one (very long, invalid) path string.

The **installed gem** (`boukensha-0.10.0`, at
`~/.rvm/gems/ruby-4.0.5/gems/boukensha-0.10.0/lib/boukensha_loader.rb`) is
byte-for-byte the step 10 loader — this is what actually runs when you type
`boukensha` at a shell prompt, not whatever step directory you happen to be
sitting in.

## Failure mode observed

A dev machine had `~/.boukensharc` left over from step 9 work:

```
boukensha_path: /home/.../week1_baseline/ruby/10_standard_tool_library
boukensha_dir: /home/.../claude-code-camp-2026-Q2/.boukensha
```

Running `boukensha` (resolving to the installed 0.10.0 gem, i.e. the step 10
loader) produced:

```
boukensha: ~/.boukensharc points to boukensha_path: /home/.../10_standard_tool_library
boukensha_dir: /home/.../claude-code-camp-2026-Q2/.boukensha
       but no lib/boukensha.rb was found there.
       Update ~/.boukensharc or remove it to use the bundled default.
```

The two-line YAML file got read whole and `.strip`ped as a single path.
`File.expand_path` of that multi-line garbage doesn't raise — it just
produces a directory that can't possibly contain `lib/boukensha.rb`, so the
loader aborts. The abort message interpolates the raw (still multi-line)
`dir` value, which is why the error appears to "echo the file back" — that
*is* what got treated as the path.

The `lib/boukensha.rb` step 10 was pointing at genuinely existed on disk;
the file was never the problem. The rc file's **format** was the problem.

## Fix applied (this machine, this incident)

Rewrote `~/.boukensharc` down to the single-line format step 10's loader
expects, and dropped `boukensha_dir` (not supported by that loader — use
`BOUKENSHA_DIR=...` env var instead if a non-default config dir is needed):

```
/home/andrew/Sites/omenking/claude-code-camp-2026-Q2/week1_baseline/ruby/10_standard_tool_library
```

This is a workaround for one machine, not a repo fix — the underlying
contract mismatch between step 9 and step 10 loaders is unchanged.

## What future steps need to do about this

Pick one, deliberately, rather than letting it keep drifting:

1. **Restore YAML support in step 10+ loaders**, keeping the step-9
   `boukensha_path` / `boukensha_dir` keys and the bare-string backward-compat
   branch. This is the only option that doesn't strand step-9-era rc files.
2. **Keep step 10's simpler bare-path contract**, but make the loader
   *detect* a YAML/multi-line rc file and abort with a message that names the
   actual problem ("this file looks like the old step-9 format; run
   `boukensha --migrate-rc` / manually reduce it to one line") instead of
   silently mis-parsing it and dumping raw file contents into the error.
3. **Document the breaking change explicitly** in whichever step first drops
   YAML support, with a one-line migration note ("if you set `boukensha_dir`
   in `~/.boukensharc` during step 9, switch to `BOUKENSHA_DIR` env var — this
   step's loader no longer reads that key").

Whichever is chosen, update this doc and the affected step's README so the
contract is traceable without re-diffing every `boukensha_loader.rb` across
steps.

See also: [`docs/plans/floating_artifacts/README.md`](README.md) for the
running list of functionality that a step built but a later step's rewrite
failed to carry forward.
