# bubbletea native-extension patch (pending-input buffer)

The `bubbletea` gem ships as a **precompiled platform gem**, and this fix lives
in its C extension — i.e. *outside* this repo, under
`~/.rvm/.../gems/bubbletea-0.1.4-<platform>/`. That copy is **lost whenever the
gem is reinstalled** (e.g. `bundle install` re-downloading the native gem).

These files are the versioned source of truth so the fix is reproducible:

This directory is **self-contained** — the patched sources and the apply
script all live here:

| file | what it is |
|------|------------|
| `program.c`, `extension.h` | the **patched** extension sources (authoritative; copied into the installed gem by the script) |
| `bubbletea-pending-input.patch` | unified diff vs pristine upstream, for review / upstreaming to `marcoroth/bubbletea-ruby` |
| `patch_bubbletea.rb` | the apply script (re-applies the sources to the installed gem and rebuilds) |

## What the patch does

`program_poll_event` did one `read()` of up to 256 bytes, parsed a **single**
key event from the front, and **discarded the rest**. When more than one byte
arrived in a single `read()` — routine for pastes and for fast typing on WSL2
ptys — every byte after the first was lost (often including `Enter`).

The patch adds a `pending_buf` / `pending_len` to the program struct. After
parsing one event, any unconsumed bytes are stashed and drained on the next
`poll_event` call *before* reading stdin again, so multi-byte chunks yield all
their key events. Verified: a single-burst write of 43 chars now produces 43
key events (was 1).

## Re-applying after a gem reinstall

From anywhere inside the `11_tui` project (bundler finds the Gemfile up the
tree):

```sh
bundle exec ruby patches/bubbletea/patch_bubbletea.rb
```

…or from this directory directly:

```sh
cd patches/bubbletea && bundle exec ruby patch_bubbletea.rb
```

This copies the patched sources into the installed gem, rebuilds the C glue
against the gem's **prebuilt `libbubbletea.a`** (no Go toolchain needed),
strips debug info, installs the `.so` for the current Ruby ABI, and load-checks
it. To revert to the pristine gem: `gem pristine bubbletea`.

## Related, but separate

This is **only** the burst-discard fix. A second, independent dropped-input bug
— `charm` loading `ntcharts`, whose Go runtime breaks bubbletea's input reader —
is fixed repo-side in `lib/boukensha/tui.rb` (require `bubbletea`/`lipgloss`/
`bubbles` instead of `charm`) and needs no rebuild. See
`docs/tui_typing_latency_plan.md`.
