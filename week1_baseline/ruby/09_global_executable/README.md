# Step 8 — Global Executable

Package BOUKENSHA as a gem so the `boukensha` command works from anywhere on your machine.

## What this step adds

- `boukensha.gemspec` — declares the gem: name, version, which files to include, and the `bin/boukensha` executable
- `bin/boukensha` — the shebang script that becomes the global command
- `lib/boukensha_loader.rb` — resolves the step folder and runtime config directory, then boots the REPL
- `lib/boukensha.rb` + `lib/boukensha/` — step 7's lib, bundled as the default

## Install

```bash
cd 09_global_executable
gem build boukensha.gemspec
gem install boukensha-0.9.0.gem
```

After that, `boukensha` is on your `$PATH` and works from any directory.

## Configuring the global executable

`~/.boukensharc` is a YAML file that can configure both the implementation to
load and the directory containing `.env`, `settings.yaml`, and `prompts/`:

```yaml
boukensha_path: ~/Sites/boukensha/08_the_repl_loop
boukensha_dir: ~/Sites/boukensha/.boukensha
```

Each value is resolved independently:

| Setting | First priority | Second priority | Default |
|---------|----------------|-----------------|---------|
| Implementation | `BOUKENSHA_PATH` | `boukensha_path` in `~/.boukensharc` | Bundled implementation |
| Runtime config | `BOUKENSHA_DIR` | `boukensha_dir` in `~/.boukensharc` | `~/.boukensha` |

`BOUKENSHA_PATH` must point to a step folder that contains `lib/boukensha.rb`.
The original single-path `.boukensharc` format is still accepted and is treated
as `boukensha_path`.

## Running a specific step

```bash
# step 7 (interactive REPL)
BOUKENSHA_PATH=~/Sites/boukensha/07_the_repl_loop boukensha

# step 6 doesn't have a REPL — loader tells you how to run it
BOUKENSHA_PATH=~/Sites/boukensha/06_the_run_dsl boukensha
# => boukensha: the step at .../06_the_run_dsl does not support the interactive REPL
#    Run its examples directly, e.g.: ruby .../06_the_run_dsl/examples/*.rb
```

## Debug mode

```bash
BOUKENSHA_DEBUG=1 boukensha
# => [boukensha] loading from: /path/to/step
```

## The key idea

The gem is just a **wrapper and a default**. All the teaching material stays in the numbered step folders exactly as it was. The gem doesn't copy or symlink anything — it just knows where to look.
