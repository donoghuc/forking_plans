require 'bolt/target'
require 'bolt/result_set'
require 'bolt/result'
Puppet::Functions.create_function(:'bolt_test::fake_task') do
    dispatch :fake_task do
      param 'Integer', :num_targets
      param 'Integer', :task_result_size
      param 'TargetSpec', :target
    end
  
    def fake_task(num_targets, task_result_size, target)
      fake_data = 'a' * task_result_size
      Bolt::ResultSet.new(num_targets.times.map {|i| Bolt::Result.new(Bolt::Target.from_asserted_hash({'name' => "target_#{i}"}), value: {'message' => fake_data})})
    end
  end