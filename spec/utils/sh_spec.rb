require 'rails_helper'

RSpec.describe Sh do
  describe '.run' do
    it 'runs commands without an environment override' do
      stdout, stderr, status = described_class.run([RbConfig.ruby, '-e', 'print ENV.fetch("PATH")'])

      expect(status).to be_success
      expect(stderr).to eq('')
      expect(stdout).not_to be_empty
    end

    it 'passes environment overrides to commands' do
      stdout, stderr, status = described_class.run(
        [RbConfig.ruby, '-e', 'print ENV.fetch("SH_TEST_VALUE")'],
        env: {'SH_TEST_VALUE' => 'expected'}
      )

      expect(status).to be_success
      expect(stderr).to eq('')
      expect(stdout).to eq('expected')
    end
  end

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

    it 'names the signal that killed the command when it has no exit status and no stderr' do
      status = instance_double(Process::Status, success?: false, exitstatus: nil, termsig: 9)

      expect {
        described_class.assert_success!('Failed to compress audio', '', status: status)
      }.to raise_error(Sh::Error, 'Failed to compress audio: command failed: signal 9')
    end
  end
end
