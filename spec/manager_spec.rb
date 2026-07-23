require 'spec_helper'

RSpec.describe Manager do
  it 'serializes generated media upload errors for DRb clients' do
    manager = described_class.new
    bot     = double
    allow(manager).to receive(:bot).and_return(bot)
    allow(bot).to receive(:upload_generated_media).and_raise(StandardError, 'upload failed')

    error = begin
      manager.upload_generated_media(chat_id: 123, type: :audio)
      nil
    rescue RuntimeError => e
      e
    end

    expect(error.message).to eq('StandardError: upload failed')
    expect(error.cause).to be_nil
  end
end
