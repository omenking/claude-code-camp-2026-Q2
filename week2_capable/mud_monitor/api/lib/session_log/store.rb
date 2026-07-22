module SessionLog
  # Directory listing and safe path resolution for session .jsonl files.
  class Store
    class NotFound < StandardError; end

    def initialize(dir:, live_window: 10)
      @dir         = Pathname.new(dir)
      @live_window = live_window
    end

    # Newest-first by filename. Session ids are `%Y%m%dT%H%M%SZ`-prefixed, so
    # lexical sort == chronological.
    def paths
      return [] unless @dir.directory?

      @dir.glob("*.jsonl").sort.reverse
    end

    # Resolves `id` to a path inside the configured directory only.
    # `File.basename` strips any path components, and a realpath prefix
    # check rejects anything that still escapes the directory (e.g. a
    # crafted basename colliding with a symlink).
    def path_for(id)
      safe_id = File.basename(id.to_s)
      path    = @dir.join("#{safe_id}.jsonl")
      raise NotFound, id unless path.file?

      resolved = path.realpath
      raise NotFound, id unless resolved.to_s.start_with?(@dir.realpath.to_s + File::SEPARATOR)

      resolved
    end

    def live?(path)
      Time.now - File.mtime(path) <= @live_window
    end
  end
end
