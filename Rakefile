# frozen_string_literal: true

require "rbconfig"

require "rake/testtask"

Rake::TestTask.new { |test| test.pattern = "test/**/*_test.rb" }

task :test do
  sh "node", "--test", "test/vite_test.mjs"
end

desc "Exercise real Docker/Vite routing, configuration, and lifecycle contracts"
task "test:docker" do
  sh RbConfig.ruby, "test/docker_integration.rb"
end

task default: :test
