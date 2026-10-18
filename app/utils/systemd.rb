module Utils
  # The instances of a systemd template unit, as far as the workers need: which are active, and starting more.
  class Systemd
    # `unit` is the template without its instance, e.g. media-downloader-tdbot-worker.
    def active(unit) = `systemctl list-units --plain --no-legend --state=active,activating '#{unit}@*'`.scan(/@(\d+)\.service/).flatten.map(&:to_i)

    def start(unit, instances) = instances.each { |instance| system('systemctl', 'start', '--no-block', "#{unit}@#{instance}.service", exception: true) }
  end
end
