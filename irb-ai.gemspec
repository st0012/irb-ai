# frozen_string_literal: true

require_relative "lib/irb/ai/version"

Gem::Specification.new do |spec|
  spec.name = "irb-ai"
  spec.version = IRB::AI::VERSION
  spec.authors = ["Stan Lo"]
  spec.email = ["stan001212@gmail.com"]

  spec.summary = "IRB commands powered by AI."
  spec.description =
    "IRB-AI is an experimental project that explores various ways to enhance users' IRB experience through AI."
  spec.homepage = "https://github.com/st0012/irb-ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/st0012/irb-ai"
  spec.metadata["changelog_uri"] = "https://github.com/st0012/irb-ai/releases"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files =
    Dir.chdir(__dir__) do
      `git ls-files -z`.split("\x0")
        .reject do |f|
          (File.expand_path(f) == __FILE__) ||
            f.start_with?(
              *%w[bin/ test/ spec/ features/ .git .circleci appveyor]
            )
        end
    end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "irb", "~> 1.6"
  spec.add_dependency "tracer", "~> 0.2.2"
  spec.add_dependency "ruby-openai", "~> 4.1"
  spec.add_dependency "tty-markdown", "~> 0.7.2"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
