Gem::Specification.new do |s|
  s.name = "traim"
  s.version = "0.3.1"
  s.summary = %{Resource-oriented microframework for RESTful API}
  s.description = %Q{Resource-oriented microframework for RESTful API}
  s.authors = ["Travis Liu"]
  s.email = ["travisliu.tw@gmail.com"]
  s.homepage = "https://github.com/travisliu/traim"
  s.license = "MIT"

  s.files = `git ls-files`.split("\n")

  s.rubyforge_project = "traim"
  
  s.add_dependency "rack", "~> 2.0"
  s.add_dependency "seg", "~> 1.2"

  s.add_development_dependency "cutest", "1.2.3"
  s.add_development_dependency "rack-test", "0.6.3"
end
