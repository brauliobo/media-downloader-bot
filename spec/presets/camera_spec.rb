require 'spec_helper'

RSpec.describe Presets::Camera do
  it 'applies camera compression defaults without overriding explicit opts' do
    opts = SymMash.new(camera: 1, quality: 24)

    described_class.apply(opts)

    expect(opts.cuda).to eq(1)
    expect(opts.format).to eq('h265')
    expect(opts.quality).to eq(24)
    expect(opts.acodec).to eq('aac')
    expect(opts.abrate).to eq('32')
  end

  it 'records generated option args for CLI delegation' do
    opts = SymMash.new(camera: 1)
    option_args = %w[camera]

    described_class.apply(opts, option_args: option_args)

    expect(option_args).to include('cuda', 'format=h265', 'quality=32', 'acodec=aac', 'abrate=32')
  end
end
