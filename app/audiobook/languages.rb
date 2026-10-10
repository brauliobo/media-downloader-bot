module Audiobook
  # Which language a book is read from and which it is read in. alang is the source override;
  # slang or lang is the speech target. lang= expands to matching alang+slang, and that pair is a
  # target, not a source.
  module Languages
    module_function

    def source(opts)
      alang = code(opts&.alang)
      alang unless alang && alang == speech(opts)
    end

    def speech(opts) = code(opts&.slang) || code(opts&.lang)

    def code(value) = value.to_s.strip.presence
  end
end
