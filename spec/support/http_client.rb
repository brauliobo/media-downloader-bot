def stub_http_client
  agent = double('mechanize')
  allow(Utils::HTTP).to receive(:client).and_return(agent)
  agent
end
