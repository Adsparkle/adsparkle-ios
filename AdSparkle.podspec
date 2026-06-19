Pod::Spec.new do |s|
  s.name             = 'AdSparkle'
  s.version          = '0.1.1'
  s.summary          = 'AdSparkle iOS SDK — client-side conversion tracking for the AdSparkle affiliate platform.'
  s.description      = <<-DESC
    AdSparkle iOS SDK provides click-capture, conversion tracking,
    offline retry queuing, and anonymous user identification for the
    AdSparkle affiliate platform. Pure Foundation — zero third-party
    dependencies. Supports iOS 13+, Swift 5.9.
  DESC

  s.homepage         = 'https://github.com/Adsparkle/adsparkle-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'ViralifAdem' => 'adem@viralif.co' }
  s.source           = { :git => 'https://github.com/Adsparkle/adsparkle-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  s.source_files = 'Sources/AdSparkle/**/*.swift'

  s.frameworks = 'Foundation', 'Network'

  # No third-party dependencies
end
