Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect(
    'ai'               => 'AI',
    'bs_roformer'      => 'BSRoformer',
    'coqui_tts'        => 'CoquiTTS',
    'drb_service'      => 'DRbService',
    'f5_tts'           => 'F5TTS',
    'ffmpeg'           => 'FFmpeg',
    'http'             => 'HTTP',
    'http_backend'     => 'HTTPBackend',
    'http_client'      => 'HTTPClient',
    'http_manager'     => 'HTTPManager',
    'http_service'     => 'HTTPService',
    'hymt2'            => 'HyMT2',
    'json_prompt'      => 'JSONPrompt',
    'json_schema'      => 'JSONSchema',
    'mdx_net'          => 'MDXNet',
    'moss_tts'         => 'MossTTS',
    'nllb_serve'       => 'NLLBServe',
    'outetts'          => 'OuteTTS',
    'td_bot'           => 'TDBot',
    'tts'              => 'TTS',
    'vtt'              => 'VTT'
  )
end

# tdlib is only bundled for the TD_BOT process; these need it at load time
unless ENV['TD_BOT']
  Rails.autoloaders.main.ignore Rails.root.join('app/bots/bot/td_bot.rb'), Rails.root.join('app/bots/td_bot/post_editor.rb')
end
