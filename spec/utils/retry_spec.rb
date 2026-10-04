require 'rails_helper'

RSpec.describe Utils::Retry do
  describe '.http' do
    it 'retries EOF and then returns' do
      calls = 0
      allow(Kernel).to receive(:sleep)
      expect(Utils::HTTP).to receive(:reset!).exactly(3).times

      result = described_class.http do
        calls += 1
        raise EOFError if calls <= 3

        :ok
      end

      expect(result).to eq(:ok)
      expect(calls).to eq(4)
      expect(Kernel).to have_received(:sleep).with(2).exactly(3).times
    end

    it 'retries HTTP 500' do
      calls = 0
      error = Mechanize::ResponseCodeError.new(Struct.new(:code).new('500'))
      allow(Kernel).to receive(:sleep)

      result = described_class.http(sleep: false) do
        calls += 1
        raise error if calls < 3

        :ok
      end

      expect(result).to eq(:ok)
      expect(calls).to eq(3)
    end

    it 'does not retry HTTP 404' do
      error = Mechanize::ResponseCodeError.new(Struct.new(:code).new('404'))
      expect(Utils::HTTP).to receive(:reset!).once

      expect { described_class.http(sleep: false) { raise error } }.to raise_error(error)
    end
  end

  describe '.call' do
    it 'uses exponential backoff when a multiplier is given' do
      calls = 0
      allow(Kernel).to receive(:sleep)

      described_class.call(tries: 3, interval: 0.5, multiplier: 2.0) do
        calls += 1
        raise 'fail' if calls < 3

        :ok
      end

      expect(Kernel).to have_received(:sleep).with(0.5).once
      expect(Kernel).to have_received(:sleep).with(1.0).once
    end
  end

  describe '.tts' do
    it 'retries with the shared TTS backoff' do
      calls = 0
      allow(Kernel).to receive(:sleep)

      described_class.tts do
        calls += 1
        raise 'fail' if calls < 2

        :ok
      end

      expect(calls).to eq(2)
      expect(Kernel).to have_received(:sleep).with(0.5).once
    end
  end
end
