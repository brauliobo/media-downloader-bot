def stub_http_client
  agent = double('mechanize')
  allow(Utils::HTTP).to receive(:client).and_return(agent)
  agent
end

# A response as Net::HTTP returns it, with its body already read.
def http_response(body, code: '200')
  Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new('1.1', code, '').tap do |response|
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
  end
end
