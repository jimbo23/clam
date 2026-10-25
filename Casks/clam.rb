cask "clam" do
  version "0.1.0"
  # TODO: Replace with the actual archive SHA-256 only after an intentional release.
  sha256 "TODO..."

  # TODO: This release URL is unpublished; this cask is a local template only.
  url "https://github.com/jimbo23/clam/releases/download/v#{version}/Clam-#{version}.zip"
  name "Clam"
  desc "Menu bar toggle that prevents sleep when the lid is closed"
  homepage "https://github.com/jimbo23/clam"

  depends_on macos: :ventura

  app "Clam.app"

  uninstall launchctl: "com.jimbo23.clam.bootreset",
            quit:      "com.jimbo23.clam",
            script:    {
              executable: "/usr/bin/pmset",
              args:       ["-a", "disablesleep", "0"],
              sudo:       true,
            },
            delete:    [
              "/etc/sudoers.d/clam",
              "/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist",
            ]

  zap trash: [
    "~/Library/Application Support/Clam",
    "~/Library/Preferences/com.jimbo23.clam.plist",
  ]

  caveats <<~EOS
    The release URL and SHA-256 are placeholders; no release has been published.
    Build locally with scripts/build.sh instead of installing this template.

    Clam's optional helper can be installed using Install Helper… in the menu
    while Clam is off. Installation requires administrator authorization and
    adds narrowly scoped sudo rules plus a boot-time sleep-reset daemon.
    Without the helper, changing sleep settings requests authorization.

    Uninstalling resets disablesleep to 0 and removes Clam's helper and daemon.
    A local ad-hoc signature is not a Developer ID signature or notarization.
  EOS
end
