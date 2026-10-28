class RunPty < Formula
  desc "Run several commands concurrently in PTYs with an interactive dashboard"
  homepage "https://github.com/jachin/run-pty-zig"
  url "https://github.com/jachin/run-pty-zig/archive/refs/tags/v0.1.3.tar.gz"
  version "0.1.3"
  license "MIT"
  depends_on "zig"

  def install
    system "zig", "build", "install", "--prefix", prefix
  end

  test do
    system bin/"run-pty", "--help"
  end
end
