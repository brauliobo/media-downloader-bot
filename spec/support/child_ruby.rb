# rails_helper sets TD_BOT for this process only: a child ruby evaluates the Gemfile again and would require the tdlib gems
RSpec.configure do |config|
  config.around(:each, :child_ruby) do |example|
    td_bot = ENV.delete('TD_BOT')
    example.run
  ensure
    ENV['TD_BOT'] = td_bot
  end
end
