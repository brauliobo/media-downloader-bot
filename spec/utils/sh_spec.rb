require 'spec_helper'

RSpec.describe Sh do
  describe '.assert_success!' do
    it 'raises a structured error with stderr' do
      status = instance_double(Process::Status, success?: false, exitstatus: 127)

      expect {
        described_class.assert_success!('ffprobe failed', 'missing lib', status: status)
      }.to raise_error(Sh::Error) { |error|
        expect(error.user_message).to eq('ffprobe failed: missing lib')
      }
    end

    it 'falls back to exit status when stderr is blank' do
      status = instance_double(Process::Status, success?: false, exitstatus: 127)

      expect {
        described_class.assert_success!('ffprobe failed', '', status: status)
      }.to raise_error(Sh::Error, 'ffprobe failed: command failed: 127')
    end
  end
end
