require "test_helper"

module SessionLog
  class StoreTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    test "paths lists sessions newest-first by filename" do
      store = Store.new(dir: FIXTURES)

      ids = store.paths.map { |p| File.basename(p, ".jsonl") }
      assert_equal ids, ids.sort.reverse
      assert_includes ids, "complete"
    end

    test "path_for resolves a bare id inside the directory" do
      store = Store.new(dir: FIXTURES)

      assert_equal FIXTURES.join("complete.jsonl").realpath, store.path_for("complete")
    end

    test "path_for raises NotFound for a missing id" do
      store = Store.new(dir: FIXTURES)

      assert_raises(Store::NotFound) { store.path_for("does-not-exist") }
    end

    test "path_for raises NotFound for a path traversal attempt" do
      store = Store.new(dir: FIXTURES)

      assert_raises(Store::NotFound) { store.path_for("../../../../etc/passwd") }
      assert_raises(Store::NotFound) { store.path_for("..%2F..%2Fetc%2Fpasswd") }
    end

    test "an empty or missing directory returns no paths" do
      store = Store.new(dir: FIXTURES.join("does-not-exist"))

      assert_empty store.paths
    end
  end
end
