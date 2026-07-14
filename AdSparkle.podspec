Pod::Spec.new do |s|
  s.name             = 'AdSparkle'
  s.version          = '0.1.4'
  s.summary          = 'iOS client SDK for the AdSparkle affiliate attribution tracking platform.'
  s.description       = <<-DESC
AdSparkle is the official iOS client SDK for the AdSparkle tracking platform.
It lets mobile apps capture affiliate attribution from deep links and send
conversion events (install, sign_up, login, download, purchase, subscription, refund)
to the tracking postback endpoint. It only uses a publishable company key ("co_")
and never any HMAC/secret.
                       DESC
  s.homepage         = 'https://github.com/Adsparkle/adsparkle-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'AdSparkle' => 'dev@adsparkle.co' }
  s.source           = { :git => 'https://github.com/Adsparkle/adsparkle-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.7']

  s.source_files     = 'Sources/AdSparkle/**/*.swift'

  # App Store zorunlu Privacy Manifest — CocoaPods'ta resource_bundle icinde
  # tasinmali (aksi halde .xcprivacy son app bundle'ina girmez).
  s.resource_bundles = {
    'AdSparkle' => ['Sources/AdSparkle/PrivacyInfo.xcprivacy']
  }
end
