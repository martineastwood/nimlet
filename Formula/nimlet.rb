# frozen_string_literal: true

class Nimlet < Formula
  desc "Minimal native coding agent"
  homepage "https://nimlet.niminal.dev"
  license "MIT"
  head "https://github.com/martineastwood/nimlet.git", branch: "main"

  # After the first tagged release, prefer a stable tarball:
  # url "https://github.com/martineastwood/nimlet/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 "REPLACE_WITH_SHASUM"
  # version "0.1.0"

  livecheck do
    url :homepage
    regex(%r{href=.*?/tag/v?(\d+(?:\.\d+)+)["' >]}i)
  end

  depends_on "nim" => :build
  depends_on "pkgconf" => :build
  depends_on "openssl@3"
  depends_on "pcre"
  depends_on "ripgrep" => :recommended

  # nimble fetches nimgent, nimterm, and nimwire from the Nimble registry
  allow_network_access! :build

  def install
    # Monorepo develop links are not present in a lone source checkout.
    rm "nimble.develop" if File.exist?("nimble.develop")
    rm "nimble.paths" if File.exist?("nimble.paths")

    openssl = Formula["openssl@3"]
    pcre = Formula["pcre"]

    ENV.prepend_path "PKG_CONFIG_PATH", openssl.opt_lib/"pkgconfig"
    ENV.append "LDFLAGS", "-L#{openssl.opt_lib} -L#{pcre.opt_lib}"
    ENV.append "CPPFLAGS", "-I#{openssl.opt_include} -I#{pcre.opt_include}"

    system "nimble", "install", "-d", "-y"

    mkdir_p "build"
    system "nim", "c",
           "-d:release",
           "--threads:on",
           "--mm:orc",
           "--dynlibOverride:pcre",
           "--passL:-L#{openssl.opt_lib}",
           "--passL:-lssl",
           "--passL:-lcrypto",
           "--passL:-L#{pcre.opt_lib}",
           "--passL:-lpcre",
           "-o:build/nimlet",
           "src/nimlet.nim"

    bin.install "build/nimlet"
  end

  test do
    assert_match "nimlet", shell_output("#{bin}/nimlet --version")
  end
end
