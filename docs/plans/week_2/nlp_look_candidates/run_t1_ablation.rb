#!/usr/bin/env ruby
# frozen_string_literal: true
#
# T1 ablation — is the context signal real, or are my hand-built proxies bad?
#   ruby run_t1_ablation.rb
#
# Zone split only, 3 epochs, to keep this cheap. Compares feature families so we
# can tell WHY T1 failed to beat the lexicon: no context signal in the data, or
# no context signal in MY FEATURES. Those imply very different next moves.

require_relative "lib/common"
require_relative "run_t1_lib"

rooms = LC.load_rooms
by_v  = rooms.to_h { |r| [r.vnum, r] }
sp    = LC.splits
tr    = sp["zone"]["train"].map { |v| by_v[v] }.compact
te    = sp["zone"]["test"].map  { |v| by_v[v] }.compact

LEX     = %w[purity log_pos log_neg seen unseen log_df]
MORPH   = %w[len plural]
POSN    = %w[pos sent first_sent ndesc]
CTX     = %w[det_a det_the adj_prev adj2 cap exist_near lead_near dir_near is_dir]
STRUCT  = %w[in_name in_exit]

SETS = {
  "lexical only"            => ->(k) { LEX.include?(k) || k == "bias" },
  "context only"            => ->(k) { CTX.include?(k) || POSN.include?(k) || MORPH.include?(k) || k == "bias" },
  "context + structural"    => ->(k) { CTX.include?(k) || POSN.include?(k) || MORPH.include?(k) || STRUCT.include?(k) || k.start_with?("sector=") || k == "bias" },
  "lexical + context"       => ->(k) { !k.start_with?("suf") },
  "everything (incl suffix)" => ->(_k) { true }
}

lex, df = train_lex(tr)
tr_feats = tr.map { |r| [r, featurize(r, lex, df)] }
te_feats = te.map { |r| [r, featurize(r, lex, df)] }

puts "zone split: train #{tr.size} / test #{te.size}, test gold #{te.sum { |r| r.gold.size }}"
printf("\n  %-26s %8s %8s %8s %8s\n", "feature set", "P@3", "R@3", "F1@3", "PR-AUC")
puts "  " + "-" * 62

SETS.each do |name, keep|
  X = []; Y = []
  tr_feats.each do |r, fs|
    g = r.gold.reduce(Set.new) { |a, s| a | s }
    fs.each do |(word, f)|
      X << f.select { |k, _| keep.call(k) }
      Y << (g.include?(word) ? 1 : 0)
    end
  end
  w = fit(X, Y, epochs: 3)
  ranked = te_feats.map { |_r, fs| fs.map { |(word, f)| [word, predict(w, f.select { |k, _| keep.call(k) })] } }
  at_k, _best, auc = LC.score_ranked(te, ranked, k: 3)
  printf("  %-26s %7.1f%% %7.1f%% %7.1f%% %7.1f%%\n",
         name, at_k[:p] * 100, at_k[:r] * 100, at_k[:f1] * 100, auc * 100)
end
