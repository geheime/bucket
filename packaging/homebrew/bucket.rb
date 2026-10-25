# Formula for the tap geheime/homebrew-tap (file: Formula/bucket.rb). Checked on Homebrew 7.0.9 against the
# v0.3.0 tarball.
#
# Decision: formula that builds from the tag's source tarball, not a cask.
#   - The standard Homebrew practice for a prebuilt GUI .app is a cask (it installs into /Applications). A formula
#     cannot write outside the Homebrew prefix: the sandbox forbids it. So a formula can only keep Bucket.app inside
#     its keg and ask the user to link it (same approach as other source-built GUI formulae); that is what `caveats` does.
#   - Why still a formula: it compiles on the user's machine, so the binary is never quarantined and Gatekeeper
#     does not block the first launch, which matters because Bucket is not notarized. A cask of the release zip would
#     need either `xattr -dr com.apple.quarantine` in a postflight or the "Open Anyway" dance.
#   - Trade-off: the build needs Xcode or the Command Line Tools, and every upgrade produces a new ad-hoc signature,
#     so macOS asks for Screen Recording again after `brew upgrade`.
#   - Alternative if that trade-off is not worth it: Casks/bucket.rb in the same tap with
#       url "https://github.com/geheime/bucket/releases/download/v#{version}/Bucket-#{version}.zip"
#       app "Bucket.app"
#       postflight { system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Bucket.app"] }
#     (the cask installs into /Applications and needs no compiler).
class Bucket < Formula
  desc "Menu bar app that hands your screenshots to your terminal AI agent"
  homepage "https://github.com/geheime/bucket"
  url "https://github.com/geheime/bucket/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "f6ace7d5c303997595f9bd4d2988829a09217bb4c899272e1785456b64ab2796"
  license "MIT"
  head "https://github.com/geheime/bucket.git", branch: "main"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    app = buildpath/"Bucket.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath
    cp ".build/release/Bucket", app/"Contents/MacOS/Bucket"
    cp "scripts/Info.plist", app/"Contents/Info.plist"
    cp "brand/AppIcon.icns", app/"Contents/Resources/AppIcon.icns"
    system "/usr/bin/plutil", "-replace", "CFBundleShortVersionString", "-string", version.to_s,
           app/"Contents/Info.plist"
    system "/usr/bin/plutil", "-replace", "CFBundleVersion", "-string", version.to_s,
           app/"Contents/Info.plist"
    system "/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-",
           "--identifier", "studio.bast.bucket", app

    prefix.install app
    # `bucket search "<words>" --json` from any shell; the app binary is also the CLI.
    bin.install_symlink prefix/"Bucket.app/Contents/MacOS/Bucket" => "bucket"
    pkgshare.install "integrations"
  end

  def caveats
    <<~EOS
      Link the app so you can open it and give it permissions:
        mkdir -p ~/Applications && ln -sfn #{opt_prefix}/Bucket.app ~/Applications/Bucket.app

      If ~/Applications/Bucket.app is already a real app (from the zip), quit Bucket and
      move that copy to the Trash first; otherwise ln puts the link inside it.

      Then open Bucket, allow Screen Recording in System Settings > Privacy & Security,
      and turn off the macOS Cmd+Shift+4 shortcut (System Settings > Keyboard >
      Keyboard Shortcuts > Screenshots).

      Every `brew upgrade` builds a new ad-hoc signature, so macOS asks for Screen
      Recording again: remove Bucket from that list and add it back if the icon stays
      struck through.

      The Claude Code skill is in:
        #{opt_pkgshare}/integrations/claude-code/bucket-search
    EOS
  end

  test do
    # Headless mode on an isolated archive: no window, no permissions needed.
    output = shell_output("#{bin}/bucket --root #{testpath}/archive search nothing --json")
    assert_match(/\A\s*\[\s*\]\s*\z/, output)
    assert_match "runtime", shell_output("/usr/bin/codesign -dv #{prefix}/Bucket.app 2>&1")
  end
end
