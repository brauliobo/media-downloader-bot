# Common ground of the bin/ scripts that drive the live bot's manager (DRb): key=value argv, chat resolution and a
# progress line printed whenever it changes. Subclasses set `progress_fields` (`errors` is shown as a count).
class CliBase
  class_attribute :progress_fields

  def initialize(argv, manager:, output: $stdout)
    @manager  = manager
    @output   = output
    @resolver = ChatResolver.new(manager, output)
    @opts     = argv.to_h { |arg| arg.split('=', 2).then { |key, value| [key.to_sym, value] } }
  end

  private

  def flag(key) = @opts[key] == '1'

  def progress(state)
    shown = state.merge(errors: state[:errors].size).slice(*progress_fields)
    line  = shown.map { |field, value| "#{field}=#{value}" }.join(' ')
    @output.puts line unless line == @last
    @last = line
  end
end
