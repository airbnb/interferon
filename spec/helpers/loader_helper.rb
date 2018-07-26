# frozen_string_literal: true

### some helpers to make this work ###
# define the module we're working in
module ::Interferon::TestSources; end

# define a test loader we'll be using
class TestLoader < Interferon::DynamicLoader
  def initialize_attributes
    @loader_for = 'test fixtures'
    @type_path = 'test_sources'
    @module = ::Interferon::TestSources
  end
end
