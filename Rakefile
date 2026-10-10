# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new { |test| test.pattern = "test/**/*_test.rb" }

task :test do
  sh "node", "--test", "test/vite_test.mjs"
end

task default: :test
