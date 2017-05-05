# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'interferon/version'

Gem::Specification.new do |gem|
  gem.name          = "interferon"
  gem.version       = Interferon::VERSION
  gem.authors       = ["Igor Serebryany", "Jimmy Ngo"]
  gem.email         = ["igor.serebryany@airbnb.com", "jimmy.ngo@airbnb.com"]
  gem.description   = %q{: Store metrics alerts in code!}
  gem.summary       = %q{: Store metrics alerts in code!}
  gem.homepage      = "https://www.github.com/airbnb/interferon"
  gem.licenses      = ['MIT']

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})

  gem.add_runtime_dependency "dogapi", "~> 1.27", ">= 1.27.0"
  gem.add_runtime_dependency "aws-sdk", "~> 1.35", ">= 1.35.1"
  gem.add_runtime_dependency "dogstatsd-ruby", "~> 1.4", ">= 1.4.1"
  gem.add_runtime_dependency "diffy", "~> 3.1.0", ">= 3.1.0"
  gem.add_runtime_dependency "parallel", "~> 1.9", ">= 1.9.0"
  gem.add_runtime_dependency "nokogiri", "< 1.7.0"
  gem.add_runtime_dependency "tzinfo", "~> 1.2.2", ">= 1.2.2"

  gem.add_development_dependency "rspec", "~> 3.2"
  gem.add_development_dependency "pry", "~> 0.10"
end
