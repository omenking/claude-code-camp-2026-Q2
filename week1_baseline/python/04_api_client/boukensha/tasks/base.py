import os
from pathlib import Path


class Base:
    """Abstract stateless task. All behaviour is expressed as classmethods
    that accept a settings dict — no instances are created. Concrete
    subclasses define task_name().
    """

    @classmethod
    def task_name(cls):
        raise NotImplementedError(f"{cls} must define task_name()")

    @classmethod
    def provider(cls, settings):
        value = cls._fetch(settings, "provider")
        if value is None:
            raise ValueError(f"tasks.{cls.task_name()}.provider is required in settings.yaml")
        return value

    @classmethod
    def model(cls, settings):
        value = cls._fetch(settings, "model")
        if value is None:
            raise ValueError(f"tasks.{cls.task_name()}.model is required in settings.yaml")
        return value

    @classmethod
    def is_prompt_override(cls, settings, prompt="system"):
        node = cls._fetch(settings, "prompt_override")
        if not isinstance(node, dict):
            return False
        return node.get(prompt) is True

    @classmethod
    def prompt(cls, settings, name="system", user_prompts_dir=None, default_prompts_dir=None):
        if cls.is_prompt_override(settings, name):
            text = cls._read_user_prompt(name, user_prompts_dir=user_prompts_dir)
            if text:
                return text

        return cls._read_default_prompt(name, default_prompts_dir=default_prompts_dir)

    @classmethod
    def system_prompt(cls, settings, user_prompts_dir=None, default_prompts_dir=None):
        return cls.prompt(
            settings,
            "system",
            user_prompts_dir=user_prompts_dir,
            default_prompts_dir=default_prompts_dir,
        )

    @classmethod
    def _fetch(cls, settings, key):
        if not isinstance(settings, dict):
            return None
        return settings.get(key)

    @classmethod
    def _read_user_prompt(cls, prompt_name, user_prompts_dir=None):
        if not user_prompts_dir:
            return None
        return cls._read_file(os.path.join(user_prompts_dir, cls.task_name(), f"{prompt_name}.md"))

    @classmethod
    def _read_default_prompt(cls, prompt_name, default_prompts_dir=None):
        if not default_prompts_dir:
            return None
        return cls._read_file(os.path.join(default_prompts_dir, f"{prompt_name}.md"))

    @classmethod
    def _read_file(cls, path):
        p = Path(path)
        return p.read_text().strip() if p.exists() else None
