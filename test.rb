
require 'bolt'
require 'bolt/project'
require 'bolt/analytics'
require 'bolt/executor'
require 'bolt/config'
require 'bolt/plugin'
require 'bolt/inventory'
require 'bolt/application'

## Steal some forking stuff from puppet based on conversation from https://github.com/puppetlabs/bolt/pull/892/files

# stolen from https://github.com/puppetlabs/puppet/blob/ed44890fa0a85e307d2a15cce20406fa279a70e5/lib/puppet/util.rb#L528
def safe_posix_fork(stdin = $stdin, stdout = $stdout, stderr = $stderr, &block)
  Kernel.fork do
    $stdin.reopen(stdin)
    $stdout.reopen(stdout)
    $stderr.reopen(stderr)

    $stdin = STDIN
    $stdout = STDOUT
    $stderr = STDERR

    begin
      Dir.foreach('/proc/self/fd') do |f|
        if f != '.' && f != '..' && f.to_i >= 3
          begin
            IO.new(f.to_i).close
          rescue StandardError
            nil
          end
        end
      end
    rescue Errno::ENOENT, Errno::ENOTDIR # /proc/self/fd not found, /proc/self not a dir\
      ## CODEREVIEW: not sure what this does. It was closing file descriptors that were required for loading code
      # 3.upto(256) do |fd|
      #   IO.new(fd).close
      # rescue StandardError
      #   nil
      # end
    end

    block&.call
  end
end

# stolen from https://github.com/puppetlabs/puppet/blob/6b1a1307a0d23a9e24f727c476d4c738b54052ef/lib/puppet/util/execution.rb#L147
def execute_plan(application, plan_name)
  begin
    reader, stdout = IO.pipe
    stdin = File.open('/dev/null', 'w+')
    stderr = File.open('/dev/null', 'w+')
    output = ''

    child_pid = nil
    begin
      child_pid = safe_posix_fork(stdin, stdout, stderr) do
        begin
          puts application.run_plan(plan_name, [])
        rescue StandardError => e
          puts "bolt failed to run"
          puts e
          puts e.backtrace
        end
      end
      [stdin, stdout, stderr].each do |io|
        io.close
      rescue StandardError
        nil
      end
      # Use non-blocking read to check for data. After each attempt,
      # check whether the child is done. This is done in case the child
      # forks and inherits stdout, as happens in `foo &`.
      until results = Process.waitpid2(child_pid, Process::WNOHANG)

        # If not done, wait for data to read with a timeout
        # This timeout is selected to keep activity low while waiting on
        # a long process, while not waiting too long for the pathological
        # case where stdout is never closed.
        ready = IO.select([reader], [], [], 0.1)
        begin
          output << reader.read_nonblock(4096) if ready
        rescue Errno::EAGAIN
        rescue EOFError
        end
      end

      # Read any remaining data. Allow for but don't expect EOF.
      begin
        loop do
          output << reader.read_nonblock(4096)
        end
      rescue Errno::EAGAIN
      rescue EOFError
      end

      # Force to external encoding to preserve prior behavior when reading a file.
      # Wait until after reading all data so we don't encounter corruption when
      # reading part of a multi-byte unicode character if default_external is UTF-8.
      output.force_encoding(Encoding.default_external)
      exit_status = results.last.exitstatus
      child_pid = nil
    rescue Timeout::Error => e
      # NOTE: For Ruby 2.1+, an explicit Timeout::Error class has to be
      # passed to Timeout.timeout in order for there to be something for
      # this block to rescue.
      unless child_pid.nil?
        Process.kill(:TERM, child_pid)
        # Spawn a thread to reap the process if it dies.
        Thread.new { Process.waitpid(child_pid) }
      end

      raise e
    end
  ensure
    # Make sure all handles are closed in case an exception was thrown attempting to execute.
    [stdin, stdout, stderr].each do |io|
      io.close
    rescue StandardError
      nil
    end
  end

  output
end


## Load bolt and get an application instance we can use to run plans in a fork
project = Bolt::Project.find_boltdir(Dir.pwd)
config = Bolt::Config.from_project(project, {})
analytics = Bolt::Analytics::NoopClient.new
executor = Bolt::Executor.new(
  config.concurrency,
  analytics,
  false,
  config.modified_concurrency,
  config.future
)
pal = Bolt::PAL.new(
  Bolt::Config::Modulepath.new(config.modulepath),
  config.hiera_config,
  config.project.resource_types,
  config.compile_concurrency,
  config.trusted_external,
  config.apply_settings,
  config.project
)
plugins = Bolt::Plugin.new(config, pal, analytics)
inventory = Bolt::Inventory.from_config(config, plugins)
application = Bolt::Application.new(
  analytics: analytics,
  config: config,
  executor: executor,
  inventory: inventory,
  pal: pal,
  plugins: plugins
)


## At this point we have loaded enough bolt code to experiment with forking plan execution after this point in 
## the lifecycle. The current execute_plan forks a single process and waits. We should refactor it to fork N processes and wait
puts execute_plan(application, 'bolt_test')