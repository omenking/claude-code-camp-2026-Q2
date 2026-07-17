While working through the steps there are some major changes we need that need to carry foward for future steps:

Artifacts:
- [bounkensharc.md](bounkensharc.md) — step 9 built YAML `~/.boukensharc` support (`boukensha_path:`/`boukensha_dir:` keys, with bare-string backward compat). Step 10 rewrote the loader and that support never got carried forward — not deprecated on purpose, just dropped. Read before touching any `boukensha_loader.rb`.