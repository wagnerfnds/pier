#!/usr/bin/env ruby
# Generates a separate XcodeGen spec without changing the production spec, plists or signing configuration.
require 'json'
require 'yaml'
require 'fileutils'

root = File.expand_path('../..', __dir__)
Dir.chdir(root)
spec = YAML.load_file('project.yml')
spec['name'] = 'PierLocalTest'
spec.delete('configFiles') # Never read a person's Config/Signing.xcconfig.
spec['configs'] = { 'Debug' => 'debug' }
spec['settings']['base'].merge!({
  'PIER_BUNDLE_ID' => 'dev.pier.app.chatfix',
  'PIER_KEYCHAIN_SERVICE' => 'dev.pier.app.chatfix',
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY' => '-',
  'DEVELOPMENT_TEAM' => '',
  'CODE_SIGNING_ALLOWED' => 'YES',
  'CODE_SIGNING_REQUIRED' => 'NO',
  'ENABLE_HARDENED_RUNTIME' => 'NO',
  'SWIFT_OPTIMIZATION_LEVEL' => '-O',
  'SWIFT_COMPILATION_MODE' => 'wholemodule',
  'DEBUG_INFORMATION_FORMAT' => 'dwarf-with-dsym',
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) DEBUG',
  'ENABLE_TESTABILITY' => 'YES'
})
targets = spec.fetch('targets')
%w[PierWidgets PierNotificationService].each { |name| targets.delete(name) }
targets.each_value do |target|
  target.delete('entitlements')
  target.delete('configFiles')
  target.delete('postBuildScripts')
  settings = target.fetch('settings', {})
  settings.fetch('base', {}).delete_if { |key, _| key.start_with?('CODE_SIGN_ENTITLEMENTS') }
  settings.fetch('configs', {}).delete('Release')
  target.fetch('dependencies', []).reject! { |dep| %w[PierWidgets PierNotificationService].include?(dep['target']) }
end
app = targets.fetch('Pier')
app['settings']['base'].merge!({
  'PRODUCT_NAME' => 'Pier Teste',
  'PRODUCT_MODULE_NAME' => 'Pier',
  'CURRENT_PROJECT_VERSION' => ENV.fetch('GITHUB_RUN_NUMBER', '1'),
  'ENABLE_APP_SANDBOX' => 'NO'
})
app['sources'].each do |source|
  next unless source.is_a?(Hash) && source['path'] == 'App'
  source['excludes'] = Array(source['excludes']) + ['Resources/Info.plist', 'Resources/*.entitlements']
end
app['info']['path'] = 'build/local-test/Info.plist'
info = app['info']['properties']
info['CFBundleDisplayName'] = 'Pier Teste'
info['PierLocalTest'] = true
%w[PierAppGroup PierKeychainGroup UIBackgroundModes BGTaskSchedulerPermittedIdentifiers].each { |key| info.delete(key) }
ui_tests = targets.fetch('PierUITests')
# The production suite contains iPhone-only device actions (Home/lock buttons). This Mac target compiles the
# self-contained conversation regression suite only; -only-testing selects tests to run, not sources to compile.
ui_tests['sources'] = [{ 'path' => 'UITests/PierUITests/ChatHistoryUITests.swift' }]
ui_tests['settings']['base'].merge!({
  'SUPPORTS_MACCATALYST' => 'YES',
  'TARGETED_DEVICE_FAMILY' => '1,2,6',
  'DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER' => 'NO'
})
spec['schemes']['Pier']['test']['targets'].each { |target| target['parallelizable'] = false }
%w[archive profile analyze].each { |action| spec['schemes']['Pier'][action] = { 'config' => 'Debug' } }
FileUtils.mkdir_p('build/local-test')
File.write('.pier-local-test.json', JSON.pretty_generate(spec) + "\n")
puts 'Generated .pier-local-test.json (Pier Teste, isolated Debug build).'
