require 'rails_helper'

RSpec.describe TDBot::MessageAttachments do
  let(:file)     { Struct.new(:size) }
  let(:document) { Struct.new(:file_name, :document) }

  def handler(msg)
    Class.new { define_method(:create_message_object) { |_| msg } }.tap { |klass| klass.prepend described_class }.new
  end

  it 'reads the document like any other bot: its name and size, and nil for what it does not have' do
    msg = handler(SymMash.new(document: document.new('a.pdf', file.new(42)))).create_message_object(nil)

    expect(msg.document).to include(file_name: 'a.pdf', file_size: 42)
    expect(msg.document.local_path).to be_nil
  end

  it 'leaves messages without attachments alone' do
    expect(handler(SymMash.new(text: 'hi')).create_message_object(nil)).to eq(SymMash.new(text: 'hi'))
  end
end
