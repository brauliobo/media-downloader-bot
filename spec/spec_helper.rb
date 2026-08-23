require_relative '../lib/manager'
require_relative '../lib/worker'
require_relative '../lib/audiobook'
require_relative '../lib/presets/camera'
require_relative '../lib/processors/folder'
require_relative 'support/ollama_mock'

def stub_http_client
  agent = double('mechanize')
  allow(Utils::HTTP).to receive(:client).and_return(agent)
  agent
end
