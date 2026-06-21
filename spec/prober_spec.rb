require 'spec_helper'

RSpec.describe Prober do
  describe '.for' do
    it 'raises stderr from ffprobe failures' do
      status = instance_double(Process::Status, success?: false, exitstatus: 127)
      allow(Sh).to receive(:run).and_return(['', 'missing libx265.so.215', status])

      expect {
        described_class.for('/tmp/input.mp4')
      }.to raise_error(Sh::Error, 'ffprobe failed for input.mp4: missing libx265.so.215')
    end
  end
end
