# frozen_string_literal: true

module HireFire
  # Alias for maintaining backwards compatibility with earlier versions of HireFire.  In previous
  # versions, the `HireFire::Resource` module was used, but in newer versions, the functionality has
  # been consolidated under the `HireFire` module. This alias ensures that existing codebases
  # referencing `HireFire::Resource` continue to function seamlessly without requiring immediate
  # refactoring to adopt the new module naming.
  Resource = HireFire
end
