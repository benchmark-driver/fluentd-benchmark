require 'tempfile'
require 'shellwords'
require 'fileutils'
require 'bundler'

class DummerRunner
  # @param [String] conf
  def initialize(conf:)
    @conf = conf
  end

  def start(rate)
    Bundler.with_clean_env do
      unless system(['bundle', 'exec', 'dummer', 'start', '-c', @conf, '-r', rate.to_s, '-d'].shelljoin, out: File::NULL)
        raise 'Failed to start dummer!'
      end
    end
  end

  def stop
    tries = 0
    loop do
      output = Bundler.with_clean_env { IO.popen('bundle exec dummer stop', &:read) }
      unless $?.success?
        raise "Failed to stop dummer!: #{output}"
      end
      if output.match(/\ADummer \d+ not running\n\z/)
        break
      else
        sleep 1
      end
    end
  end
end

class FluentdRunner
  # @param [String] conf
  def initialize(conf:)
    @conf = conf
    @log = Tempfile.new('fluentd-benchmark')
    Bundler.with_clean_env do
      @pid = Process.spawn('bundle', 'exec', 'fluentd', '-c', @conf, out: @log.path)
    end
  end

  def stop
    Process.kill(:TERM, @pid)
    Process.waitpid(@pid)
    @log.close
  end

  def read_logs
    @log.read
  end
end

class Benchmarker
  MEASURE_DURATION = 5

  # @param [String] agent_conf
  # @param [String] receiver_conf
  # @param [String] dummer_conf
  # @param [String] dummy_path
  def initialize(agent_conf:, receiver_conf:, dummer_conf:)
    @dummer   = DummerRunner.new(conf: dummer_conf)
    @agent    = FluentdRunner.new(conf: agent_conf)
    @receiver = FluentdRunner.new(conf: receiver_conf)
    at_exit do
      @agent.stop
      @receiver.stop
    end
  end

  # Measure lines/sec for given log generation rate (messages/sec)
  # @param [Integer] generate_rate - messages/sec
  # @return [Integer] - lines/sec
  def measure_lines_per_sec(generate_rate)
    @receiver.read_logs # flush unrelated logs

    @dummer.start(generate_rate)
    sleep MEASURE_DURATION
    @dummer.stop

    logs = @receiver.read_logs
    #puts "\n----------\n#{logs}----------\n\n"
    logs.scan(/plugin:out_flowcounter_simple\s+count:(\d+)/).map { |l| l.first.to_i }.max
  end

  private

  def run_dummer(rate)
    @dummer.start
  end
end

FileUtils.rm_f(File.expand_path('dummy.log', __dir__))

bench = Benchmarker.new(
  agent_conf:    File.expand_path('agent.conf', __dir__),
  receiver_conf: File.expand_path('receiver.conf', __dir__),
  dummer_conf:   File.expand_path('dummer.conf', __dir__),
)
best_lps = 0
second_lps = 0 # for later bisect

# Test 1000, 10000, 10000, ...
generate_rate = 1000 # messages/s
loop do
  puts "benchmarking with the rate: #{generate_rate} messages/s... (#{Benchmarker::MEASURE_DURATION}s)"
  lps = bench.measure_lines_per_sec(generate_rate)
  puts "  => #{lps} lines/s"
  if lps > best_lps
    best_lps = lps
    generate_rate *= 10
  else
    second_lps = lps
    break
  end
end

# If 10000 is the best rate, bisect between 10000 and 100000 (50000, 75000, 87500, ...)
# until the step falls under the 10% difference (9000 here).
best_rate = generate_rate / 10
second_rate = generate_rate
min_step = (second_rate - best_rate) / 10 # 10% step

loop do
  test_rate = (best_rate + second_rate) / 2
  if (best_rate - test_rate).abs < min_step
    break
  end

  puts "benchmarking with the rate: #{test_rate} messages/s... (#{Benchmarker::MEASURE_DURATION}s)"
  test_lps = bench.measure_lines_per_sec(test_rate)
  puts "  => #{test_lps} lines/s"

  if test_lps > best_lps # test_rate > best_rate > second_rate
    best_rate, second_rate = test_rate, best_rate
    best_lps, second_lps = test_lps, best_lps
  elsif test_lps > second_lps # best_rate > test_rate > second_rate
    best_rate, second_rate = best_rate, test_rate
    best_lps, second_lps = best_lps, test_lps
  else # best_rate > second_rate > test_rate
    break # unexpected result... stopping
  end
end

puts
puts "best result: #{best_lps} lines/s (under #{best_rate} messages/s)"
