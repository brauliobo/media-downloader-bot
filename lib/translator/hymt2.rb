class Translator
  module HyMT2
    include LlamacppApi

    private

    def llama_api_host
      ENV.fetch('HYMT2_HOST', 'http://127.0.0.1:12002')
    end

    def llama_model
      ENV.fetch('HYMT2_MODEL', 'Hy-MT2-7B-Q4_K_M.gguf')
    end

    def llama_concurrency
      [ENV.fetch('HYMT2_CONCURRENCY', 8).to_i, 1].max
    end
  end
end
