module AI
  # Claude through cli-proxy-api, which serves the Claude subscriptions on an OpenAI-compatible endpoint.
  class ClaudeProxy
    extend JSONPrompt

    API   = ENV.fetch('CLI_PROXY_API_URL', 'http://127.0.0.1:8317')
    KEY   = ENV['CLI_PROXY_API_KEY']
    MODEL = ENV.fetch('CLI_PROXY_API_MODEL', 'claude-haiku-5-5')

    def self.prompt(text, model: MODEL)
      payload = { model: model, messages: [{ role: :user, content: text }] }
      res     = Utils::HTTP.post Utils::HTTP.url(API, '/v1/chat/completions'), payload.to_json,
                                 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{KEY}"
      Utils::HTTP.assert_ok!(res, 'cli-proxy-api')
      JSON.parse(res.body).dig('choices', 0, 'message', 'content').to_s.strip
    end
  end
end
