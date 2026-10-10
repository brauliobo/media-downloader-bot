require 'rails_helper'

RSpec.describe Text::Spoken::Urls do
  it 'says where a link points instead of spelling it out' do
    expect(described_class.call('veja https://www.rumble.com/v123?x=1 agora')).to eq('veja rumble.com agora')
    expect(described_class.call('em www.site.org/a/b e tv.gab.com')).to eq('em site.org e tv.gab.com')
  end

  it 'leaves text without links alone' do
    expect(described_class.call('nada a dizer')).to eq('nada a dizer')
  end
end
