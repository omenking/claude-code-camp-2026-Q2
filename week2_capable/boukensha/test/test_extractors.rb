require_relative "helper"
require "json"
require "digest"

# `look_candidates` — the one room-survey field a script can't derive, answered
# by a local ONNX model instead of an LLM call.
#
# The load-bearing test here is the tokenizer parity fixture. Everything else in
# this stack fails loudly; a tokenizer that drifts from the one the model was
# trained with keeps returning plausible words for the wrong reasons, which is
# exactly the failure mode the whole project kept tripping over.
class TestExtractors < Minitest::Test
  MODEL_DIR = File.expand_path("../../../.boukensha/models/look_candidates", __dir__)
  FIXTURES  = File.expand_path("fixtures", __dir__)

  def fixture(name) = JSON.parse(File.read(File.join(FIXTURES, name)))

  def vocab
    @vocab ||= JSON.parse(File.read(File.join(MODEL_DIR, "vocab.json")))
  end

  def skip_without_model
    return if File.exist?(File.join(MODEL_DIR, "model.onnx"))

    skip "no model artifact — run `rake model:fetch` (or build_model.rb)"
  end

  def model
    skip_without_model
    Boukensha::Extractors::Model.reset_cache!
    Boukensha::Extractors::Model.load(MODEL_DIR)
  end

  # --- tokenizer parity ------------------------------------------------------

  # 478 words straight out of the corpus, 209 of which split into multiple
  # WordPiece pieces, with the ids Python's tokenizer produced for the very
  # checkpoint we ship. If these match, our Ruby tokenizer is the trained one.
  def test_wordpiece_matches_the_python_tokenizer_exactly
    skip_without_model
    wp = Boukensha::Extractors::WordPiece.new(vocab)
    mismatches = fixture("wordpiece_parity.json").reject { |word, ids| wp.encode_word(word) == ids }
    assert_empty mismatches.first(5), "#{mismatches.size} words tokenize differently than in training"
  end

  def test_wordpiece_falls_back_to_unk_for_an_unmatchable_word
    wp = Boukensha::Extractors::WordPiece.new({ "[UNK]" => 100, "the" => 1996 })
    assert_equal [1996], wp.encode_word("The")
    assert_equal [100],  wp.encode_word("zzzz")
  end

  # The "no tokenizers gem needed" argument rests entirely on the trainer only
  # ever feeding whole [A-Za-z] words to WordPiece — no punctuation, no accents.
  # Widen this regex and that stops being true, so make it a red build.
  def test_word_regex_is_pinned_to_the_trained_contract
    assert_equal "[A-Za-z]{2,}", Boukensha::Extractors::Model::WORD.source
    assert_equal "[a-z]{3,}", Boukensha::Extractors::Model::CANDIDATE.source
  end

  def test_stopword_list_matches_the_manifest_checksum
    skip_without_model
    manifest = JSON.parse(File.read(File.join(MODEL_DIR, "manifest.json")))
    ours = Digest::SHA256.hexdigest(Boukensha::Extractors::Model::STOP.to_a.sort.join(" "))
    assert_equal manifest["stopwords_sha256"], ours,
                 "stopword list drifted from the corpus the model was trained on"
  end

  # --- candidate pool --------------------------------------------------------

  def test_candidate_pool_is_content_words_first_occurrence_wins
    m = model
    pool = m.candidates("You are in the temple. The temple has a large statue, and the statue is old.")
    # `you/are/in/the/and/is` are stopwords or under three letters; `temple` and
    # `statue` appear twice and are pooled once, at their first position.
    assert_equal %w[temple large statue old], pool
  end

  def test_candidate_pool_is_empty_for_empty_prose
    assert_empty model.candidates("")
  end

  # --- scoring ---------------------------------------------------------------

  def test_scores_every_candidate_and_ranks_them
    m = model
    room = fixture("rooms.json").first
    ranked = m.score(name: room["name"], description: room["description"],
                     exit_targets: room["exit_targets"])

    assert_equal m.candidates(room["description"]).sort, ranked.map(&:first).sort
    assert_equal ranked, ranked.sort_by { |_w, s| -s }, "scores must come back ranked"
    assert ranked.all? { |_w, s| s.between?(0.0, 1.0) }
  end

  def test_call_respects_the_manifest_threshold_and_top_k
    m = model
    fixture("rooms.json").each do |room|
      out = m.call(name: room["name"], description: room["description"],
                   exit_targets: room["exit_targets"])
      assert_operator out.size, :<=, m.top_k
      scores = m.score(name: room["name"], description: room["description"],
                       exit_targets: room["exit_targets"]).to_h
      out.each { |w| assert_operator scores.fetch(w), :>=, m.threshold }
    end
  end

  # Built with threshold 0 so the room is guaranteed to speak — the shipped
  # threshold silences ~73% of rooms, which would make this test's outcome
  # depend on which rooms landed in the fixture.
  def talkative_model(top_k: 3, threshold: 0.0)
    skip_without_model
    Boukensha::Extractors::Model.new(
      onnx_path: File.join(MODEL_DIR, "model.onnx"), vocab: vocab,
      threshold: threshold, top_k: top_k, max_len: 256, context_fields: %w[name exits]
    )
  end

  def test_excluded_words_never_survive_however_high_they_score
    m = talkative_model
    room = fixture("rooms.json").first
    args = { name: room["name"], description: room["description"], exit_targets: room["exit_targets"] }

    spoken = m.call(**args)
    refute_empty spoken
    assert_empty spoken & m.call(**args, exclude: Set.new(spoken))
  end

  # Threshold and top_k are manifest fields, not constants — a rebuilt artifact
  # ships its own calibration (they drift together) and the runtime must follow
  # it without a code change.
  def test_threshold_and_top_k_come_from_configuration_not_code
    room = fixture("rooms.json").first
    args = { name: room["name"], description: room["description"], exit_targets: room["exit_targets"] }

    assert_equal 1, talkative_model(top_k: 1).call(**args).size
    assert_empty talkative_model(threshold: 1.01).call(**args)
  end

  # Loading the graph costs ~110ms; a survey per room must not pay it again.
  def test_the_onnx_session_is_built_once_per_directory
    skip_without_model
    Boukensha::Extractors::Model.reset_cache!
    first = Boukensha::Extractors::Model.load(MODEL_DIR)
    assert_same first, Boukensha::Extractors::Model.load(MODEL_DIR)
  end

  def test_inference_stays_far_under_the_mud_round_trip
    m = model
    room = fixture("rooms.json").first
    m.score(name: room["name"], description: room["description"], exit_targets: room["exit_targets"])
    t0 = Time.now
    5.times { m.score(name: room["name"], description: room["description"], exit_targets: room["exit_targets"]) }
    ms = (Time.now - t0) * 1000 / 5
    assert_operator ms, :<, 50, "#{ms.round(1)}ms/room — the budget assumes ~10ms"
  end

  # --- failure posture -------------------------------------------------------

  # A missing model is an honest degraded install: one warning, empty field, the
  # survey still returns.
  def test_a_missing_artifact_degrades_to_silence_with_one_warning
    Dir.mktmpdir do |dir|
      Boukensha::Extractors::Model.reset_cache!
      m = Boukensha::Extractors::Model.load(dir)
      refute m.available?
      out = nil
      err = capture_io { out = m.call(name: "Temple", description: "A large statue stands here.") }.last
      assert_empty out
      assert_match(/look_candidates disabled/, err)
      capture_io { m.call(name: "Temple", description: "A large statue stands here.") }.last.then do |second|
        assert_empty second, "the warning must not repeat per room"
      end
    end
  end

  def test_a_manifest_without_its_model_file_degrades_rather_than_raising
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.json"), JSON.generate(
        "model_file" => "model.onnx", "vocab_file" => "vocab.json",
        "threshold" => 0.8, "top_k" => 3, "max_len" => 256, "context_fields" => %w[name exits]
      ))
      Boukensha::Extractors::Model.reset_cache!
      m = Boukensha::Extractors::Model.load(dir)
      refute m.available?
      assert_match(/rake model:fetch/, capture_io { m.call(name: "", description: "") }.last)
    end
  end

  # The asymmetry that matters: a model whose parameters we can't read is worse
  # than no model, because it would silently score against the wrong recipe.
  def test_an_unreadable_manifest_raises
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.json"), "{ not json")
      Boukensha::Extractors::Model.reset_cache!
      assert_raises(Boukensha::Extractors::Model::ManifestError) do
        Boukensha::Extractors::Model.load(dir)
      end
    end
  end

  def test_a_drifted_stopword_list_raises
    skip_without_model
    Dir.mktmpdir do |dir|
      manifest = JSON.parse(File.read(File.join(MODEL_DIR, "manifest.json")))
      manifest["stopwords_sha256"] = "deadbeef" * 8
      File.write(File.join(dir, "manifest.json"), JSON.generate(manifest))
      FileUtils.cp(File.join(MODEL_DIR, "model.onnx"), File.join(dir, "model.onnx"))
      Boukensha::Extractors::Model.reset_cache!
      assert_raises(Boukensha::Extractors::Model::ManifestError) do
        Boukensha::Extractors::Model.load(dir)
      end
    end
  end

  # --- the composed seam the survey injects ----------------------------------

  # Stands in for Boukensha.config so these don't depend on the repo's own
  # settings.yaml.
  # `dir` is the boukensha dir; model_dir defaults to <dir>/models/look_candidates,
  # so these pass it explicitly rather than reconstructing that layout.
  FakeConfig = Struct.new(:dir, :settings) do
    def dig(*keys) = keys == %i[tools inspect_room look_candidates] ? settings : nil
  end

  def test_extractor_none_returns_a_lambda_that_never_speaks
    extract = Boukensha::Extractors.look_candidates(
      config: FakeConfig.new(MODEL_DIR, { "extractor" => "none", "model_dir" => MODEL_DIR })
    )
    assert_empty extract.call(name: "Temple", description: "A large statue stands here.",
                              exit_targets: {}, exclude: Set.new)
  end

  # The whole point of composing them: a caller passing raw survey output gets
  # exit names and entity keywords subtracted without knowing they exist.
  def test_composed_lambda_subtracts_exit_names_without_being_asked
    skip_without_model
    Boukensha::Extractors::Model.reset_cache!
    extract = Boukensha::Extractors.look_candidates(
      config: FakeConfig.new(MODEL_DIR, { "model_dir" => MODEL_DIR })
    )
    out = extract.call(
      name: "The Temple Of Midgaard",
      description: "A large statue stands beside the altar. The market square lies north.",
      exit_targets: { "north" => "Market Square" },
      mobs: [{ keyword: "peacekeeper", desc: "A Peacekeeper is standing here." }],
      objects: [], exclude: Set.new
    )
    refute_empty out, "a statue beside an altar is the clearest positive in the corpus"
    refute_includes out, "market"
    refute_includes out, "square"
    refute_includes out, "peacekeeper"
  end

  # --- structural subtraction (free, no model) -------------------------------

  def test_structural_subtracts_exit_names_and_entity_keywords
    ex = Boukensha::Extractors::Structural.exclusions(
      exit_targets: { "north" => "The Market Square", "west" => "Poor Alley" },
      mobs: [{ keyword: "peacekeeper", desc: "A Peacekeeper is standing here." }],
      objects: [{ "keyword" => "fountain", "desc" => "A large fountain is here." }]
    )
    assert_includes ex, "market"
    assert_includes ex, "alley"
    assert_includes ex, "peacekeeper"
    assert_includes ex, "fountain"
  end

  # Entity long-descriptions are deliberately left in: "mucking through the
  # garbage" must not cost us `garbage`, which is exactly the kind of noun a
  # builder hides a description on.
  def test_structural_keeps_nouns_that_merely_co_occur_with_a_mob
    ex = Boukensha::Extractors::Structural.exclusions(
      mobs: [{ keyword: "fido", desc: "A beastly fido is mucking through the garbage." }]
    )
    assert_includes ex, "fido"
    refute_includes ex, "garbage"
  end

  def test_structural_is_empty_for_an_empty_room
    assert_empty Boukensha::Extractors::Structural.exclusions
  end
end
