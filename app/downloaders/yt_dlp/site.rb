module Downloaders
  class YtDlp
    # What a site needs on top of yt-dlp's defaults, kept together instead of spread over the command and the format choice.
    class Site
      HOSTS = [].freeze

      def self.for(url) = (SITES.find { _1.host?(url) } || self).new

      def self.host?(url)
        host = Utils::Url.parse(url)&.host.to_s.downcase
        self::HOSTS.any? { host == _1 || host.end_with?(".#{_1}") }
      end

      # the url yt-dlp is asked for
      def resolve(url) = url
      # extra yt-dlp arguments for every run, and for the metadata run only
      def args(_opts) = []
      def info_args = []
      # the note of a format that is listed as a video but is not one (a storyboard), never to be picked
      def skipped_note = nil
      # the format to fetch for an audio request, when the site has a better one than extracting it
      def audio_format = nil
      def display(_info, url) = Utils::Url.display(url)
    end

    class Site::Rumble < Site
      HOSTS = %w[rumble.com].freeze
      # it answers 403 to browser user agents from non-browser clients
      USER_AGENT = 'curl/8.9.1'.freeze

      # the watch page answers 403 whatever the agent; the embed page of the same video does not
      def resolve(url)
        uri = Utils::Url.parse(url)
        return url if uri.path.match?(%r{\A/embed/}i)

        clean = uri.dup.tap { |u| u.query = u.fragment = nil }.to_s
        body  = Utils::HTTP.get_public("https://rumble.com/api/Media/oembed.json?#{URI.encode_www_form(url: clean)}")
        JSON.parse(body)['html'].to_s[%r{https://rumble\.com/embed/[^"']+}] || url
      rescue StandardError
        url
      end

      def args(_opts) = ["--user-agent #{Sh.escape(USER_AGENT)}"]
      def skipped_note = 'Timeline'
    end

    class Site::Youtube < Site
      HOSTS = %w[youtube.com youtu.be].freeze

      def args(opts) = opts.alang ? ["--extractor-args #{Sh.escape("youtube:lang=#{opts.alang};player_client=web_embedded,default")}"] : []
      def info_args = ["--match-filter #{Sh.escape('live_status != is_upcoming')}"]

      def display(info, url)
        id = info.id.presence || info.display_id.presence
        id ? "youtu.be/#{id}" : super
      end
    end

    class Site::Bandcamp < Site
      HOSTS = %w[bandcamp.com].freeze

      def audio_format = 'mp3-320'
    end

    Site::SITES = [Site::Rumble, Site::Youtube, Site::Bandcamp].freeze
  end
end
