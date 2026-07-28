# frozen_string_literal: true

require_relative "lib/open_in_editor_bridge/version"

Gem::Specification.new do |spec|
  spec.name = "open-in-editor-bridge"
  spec.version = OpenInEditorBridge::VERSION
  spec.summary = "Local HTTP bridge for opening container paths in an editor"
  spec.description = "Ruby API and CLI for serving local open-in-editor requests during development."
  spec.authors = ["Marlen Brunner"]
  spec.email = ["klondikemarlen@gmail.com"]
  spec.homepage = "https://github.com/klondikemarlen/open-in-editor-bridge"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["LICENSE.txt", "README.md", "exe/open-in-editor-bridge", "lib/**/*.rb"]
  spec.bindir = "exe"
  spec.executables = ["open-in-editor-bridge"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/klondikemarlen/open-in-editor-bridge/issues",
    "source_code_uri" => "https://github.com/klondikemarlen/open-in-editor-bridge",
  }
end
