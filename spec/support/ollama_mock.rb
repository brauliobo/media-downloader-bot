module OllamaMock
  def mock_ollama
    allow(AI::Ollama).to receive(:prompt).and_return('')
    allow(AI::Ollama).to receive(:chat).and_return('')
  end
end

RSpec.configure do |config|
  config.include OllamaMock
  config.before { mock_ollama }
end
