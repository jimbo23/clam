cask "clam" do
  version "0.1.0"
  sha256 "fe25b8fb00cc7629a27cb661350288d5dd3c8a9b85838acf6ba84e49cef564bf"

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
    Clam is ad-hoc signed and NOT notarized, so Gatekeeper blocks it on first
    launch. To allow it, either run:
      xattr -dr com.apple.quarantine #{appdir}/Clam.app
    or open Clam once, then go to System Settings > Privacy & Security and
    click "Open Anyway".

    One-time setup: with Clam Off, choose "Install Helper…" from its menu and
    approve the administrator prompt. This installs a sudoers rule limited to
    `/usr/bin/pmset -a disablesleep 0|1` and a LaunchDaemon that resets
    disablesleep to 0 at every boot.

    Never put a Mac with Clam On in a bag: it will stay awake and get hot.
  EOS
end
