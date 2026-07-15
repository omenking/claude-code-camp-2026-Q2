module Boukensha
  module Tasks
    class Base
      def self.task_name
        raise NotImplementedError, "#{self} must define .task_name"
      end

      def self.provider(settings)
        fetch(settings, :provider) || raise(ArgumentError, "tasks.#{task_name}.provider is required in settings.yaml")
      end

      def self.model(settings)
        fetch(settings, :model) || raise(ArgumentError, "tasks.#{task_name}.model is required in settings.yaml")
      end

      def self.prompt_override?(settings, prompt = :system)
        node = fetch(settings, :prompt_override)
        return false unless node.is_a?(Hash)

        (node[prompt.to_s] || node[prompt.to_sym]) == true
      end

      def self.prompt(settings, name = :system, user_prompts_dir: nil, default_prompts_dir: nil)
        if prompt_override?(settings, name) && (text = read_user_prompt(name, user_prompts_dir: user_prompts_dir))
          return text
        end

        read_default_prompt(name, default_prompts_dir: default_prompts_dir)
      end

      def self.system_prompt(settings, user_prompts_dir: nil, default_prompts_dir: nil)
        prompt(settings, :system, user_prompts_dir: user_prompts_dir, default_prompts_dir: default_prompts_dir)
      end

      class << self
        private

        def fetch(settings, key)
          return nil unless settings.is_a?(Hash)

          settings[key.to_s] || settings[key.to_sym]
        end

        def read_user_prompt(prompt_name, user_prompts_dir: nil)
          return nil unless user_prompts_dir

          read_file(File.join(user_prompts_dir, task_name, "#{prompt_name}.md"))
        end

        def read_default_prompt(prompt_name, default_prompts_dir: nil)
          return nil unless default_prompts_dir

          read_file(File.join(default_prompts_dir, "#{prompt_name}.md"))
        end

        def read_file(path)
          File.exist?(path) ? File.read(path).strip : nil
        end
      end
    end
  end
end
