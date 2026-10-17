module Bot
  # A job stopped to be taken again (its worker was stopped or reloaded), not failed. The stop is asked first (`request!`) and taken
  # where the job can leave its files whole: the threads of the job raise it at their checkpoints (`check!`: a status update, a task of
  # a pool), and the pools hand it to their callers. Only a job that reaches none in time has it thrown into it (see JobRunner).
  class JobRestarted < Interrupt
    class << self
      def request! = @requested = true

      def reset! = @requested = false

      def requested? = !!@requested

      def check! = (raise self if requested?)
    end
  end
end
