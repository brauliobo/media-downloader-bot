module AI
  # Claude through cli-proxy-api, which serves the Claude subscriptions on an OpenAI-compatible endpoint.
  class ClaudeProxy
    extend JSONPrompt

    API   = ENV.fetch('CLI_PROXY_API_URL', 'http://127.0.0.1:8317')
    KEY   = ENV['CLI_PROXY_API_KEY']
    MODEL = ENV.fetch('CLI_PROXY_API_MODEL', 'claude-haiku-5-5')
    # The subscription's rate limit lifts within minutes, and what is asked (a book's hashtags) is worth the wait: 20 s, then 40, 80, 160, 320.
    RATE_LIMITED = { tries: 6, interval: 20, multiplier: 2, on: [Mechanize::ResponseCodeError], retry_if: ->(error) { error.response_code == '429' } }.freeze

    def self.prompt(text, model: MODEL)
      payload = { model: model, messages: [{ role: :user, content: text }] }
      res     = Utils::Retry.call(**RATE_LIMITED) do
        Utils::HTTP.post Utils::HTTP.url(API, '/v1/chat/completions'), payload.to_json,
                         'Content-Type' => 'application/json', 'Authorization' => "Bearer #{KEY}"
      end
      Utils::HTTP.assert_ok!(res, 'cli-proxy-api')
      JSON.parse(res.body).dig('choices', 0, 'message', 'content').to_s.strip
    end
  end
end
