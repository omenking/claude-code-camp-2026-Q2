require "json"

module Boukensha
  module Extractors
    # WordPiece, in Ruby, with no gem.
    #
    # This exists because of a narrow fact about how the model was trained: the
    # trainer fed the tokenizer one `/[A-Za-z]{2,}/` word at a time. That path
    # never reaches BERT's *basic* tokenizer — no punctuation splitting, no
    # accent stripping, no CJK — so the whole of "tokenize like BERT" collapses
    # to downcase + greedy longest-match over the vocab, which is the twenty
    # lines below. Verified against the Python tokenizer over the corpus: zero
    # token-id mismatches (test/test_extractors.rb).
    #
    # If the word regex is ever widened past `[A-Za-z]`, that equivalence breaks
    # and this must be replaced by the `tokenizers` gem. `Model::WORD` is pinned
    # by a test so that change fails loudly instead of quietly re-scoring every
    # room against a tokenizer the model never saw.
    class WordPiece
      UNK = "[UNK]".freeze

      def initialize(vocab)
        @vocab = vocab
        @unk   = vocab.fetch(UNK)
      end

      def id(token) = @vocab[token]

      # One word -> its subtoken ids. Longest-match from the left, continuation
      # pieces prefixed "##", whole word -> [UNK] if any piece fails to match
      # (BERT's rule: an unmatched suffix poisons the entire word, not just the
      # tail).
      def encode_word(word)
        w   = word.downcase
        out = []
        start = 0
        while start < w.length
          finish = w.length
          piece  = nil
          while start < finish
            candidate = start.zero? ? w[start...finish] : "###{w[start...finish]}"
            if @vocab.key?(candidate)
              piece = candidate
              break
            end
            finish -= 1
          end
          return [@unk] if piece.nil?

          out << @vocab[piece]
          start = finish
        end
        out
      end
    end
  end
end
