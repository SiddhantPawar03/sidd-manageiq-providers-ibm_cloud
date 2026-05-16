# Declare your gem's dependencies in manageiq-providers-ibm_cloud.gemspec.
# Bundler will treat runtime dependencies like base dependencies, and
# development dependencies will be added by default to the :development group.
gemspec

# Declare any dependencies that are still in development here instead of in
# your gemspec. These might include edge Rails or gems from your path or
# Git. Remember to move these dependencies to your gemspec before releasing
# your gem to rubygems.org.

# Override ibm_cloud_power gem with GitHub repository version
gem "ibm_cloud_power", "~> 3.0", git: "https://github.com/shashank-gowda/ibm-cloud-sdk-ruby.git", glob: "gems/ibm_cloud_power/*.gemspec"

# Load Gemfile with dependencies from manageiq
eval_gemfile(File.expand_path("spec/manageiq/Gemfile", __dir__))
