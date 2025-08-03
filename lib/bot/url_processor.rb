require_relative 'yt_dlp'
require_relative '../td_bot/downloader'

class Bot
  # Delegates URL downloads to specialized downloader classes.
  #
  # * t.me links – handled by TDBot::Downloader (TDLib)
  # * everything else – handled by Bot::YtDlp (yt-dlp)
  class UrlProcessor < Processor

    # Pick the appropriate backend once and memoize it.
    def downloader
      @downloader ||= if url.to_s.match?(%r{\Ahttps?://t\.me/})
        TDBot::Downloader.new self
      else
        Bot::YtDlp.new self
      end
    end

    # Public API expected by Worker ------------------------------------------------
    def download(*args, **kwargs)    = downloader.download(*args, **kwargs)
    def download_one(*a, **k)        = downloader.respond_to?(:download_one) ? downloader.download_one(*a, **k) : nil
  end
end
