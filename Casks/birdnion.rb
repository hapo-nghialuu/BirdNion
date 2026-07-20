cask "birdnion" do
  version "0.9.0"
  sha256 "981c10429b01324fd75e4a46eb9e5cf366793b3586a4e4c94d49a35eba4fb7f7"

  url "https://github.com/hapo-nghialuu/BirdNion/releases/download/v#{version}/BirdNion-#{version}.zip"
  name "BirdNion"
  desc "AI quota menu bar app — tracks MiniMax, Codex, Claude, Hapo AI Hub and more"
  homepage "https://github.com/hapo-nghialuu/BirdNion"

  livecheck do
    url :homepage
    strategy :github_latest_release
  end

  depends_on :macos

  app "BirdNion.app"

  # Ad-hoc signed — strip Gatekeeper quarantine flag so users don't
  # have to Right-click → Open on first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/BirdNion.app"]
  end

  zap trash: [
    # BirdNion config + tokens
    "~/.config/birdnion",
    "~/.birdnion",
    "~/Library/Application Support/BirdNion",
    "~/Library/Preferences/com.local.birdnion.plist",
    "~/Library/Caches/com.local.birdnion",
    "~/Library/HTTPStorages/com.local.birdnion",
    "~/Library/HTTPStorages/com.local.birdnion.binarycookies",
    # Legacy (old app name AIStatusbar — kept for migration cleanup)
    "~/Library/Application Support/AIStatusbar",
    "~/Library/Preferences/com.local.aistatusbar.plist",
    "~/Library/Caches/com.local.aistatusbar",
    "~/Library/HTTPStorages/com.local.aistatusbar",
    "~/Library/HTTPStorages/com.local.aistatusbar.binarycookies",
  ]
end
