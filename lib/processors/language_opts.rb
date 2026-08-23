module Processors
  module LanguageOpts
    module_function

    def expand(opts)
      opts.slang = opts.alang = opts.lang if opts.lang.present?
      opts
    end

    def from(opts, fallback = nil)
      opts&.clang.presence || opts&.dub_lang.presence || opts&.lang.presence || opts&.slang.presence || fallback
    end
  end
end
