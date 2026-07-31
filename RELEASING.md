# Releasing

A release is a tag. Everything else — building the universal binary, checking that it works, writing the Homebrew formula, publishing — is [`.github/workflows/release.yml`](.github/workflows/release.yml).

## Cutting one

1. Set the version in `Sources/xclocsmith/Registry.swift`. It is the number `--version` prints and the number that goes into every SARIF document this build writes, which is why the workflow refuses to publish when it disagrees with the tag.
2. Move the unreleased section of [`CHANGELOG.md`](CHANGELOG.md) under the new version.
3. Tag and push:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

The workflow then runs the test suite, builds `arm64` + `x86_64` into one binary, packages `xclocsmith`, `xclocsmith-mcp`, `LICENSE` and `README.md` into `xclocsmith-<version>-macos-universal.tar.gz`, unpacks that tarball and runs the packaged binary against the bundled example project — a release nobody has executed is a release nobody has tested — and attaches it to a GitHub release along with the rendered formula.

To rehearse without publishing, run the workflow manually from the Actions tab: it builds, packages and verifies, then uploads the artefacts instead of creating a release.

## The tap

Homebrew installs from a separate repository, which by convention is `homebrew-tap` under the same owner. It has to exist before `brew install asutekku/tap/xclocsmith` resolves.

```bash
gh repo create asutekku/homebrew-tap --public \
  --description "Homebrew formulae"
```

Each release attaches an `xclocsmith.rb` with the version and checksum already filled in from [`Formula/xclocsmith.rb.template`](Formula/xclocsmith.rb.template). Publishing a version is copying that file into the tap as `Formula/xclocsmith.rb` and pushing:

```bash
gh release download v0.2.0 --repo asutekku/xclocsmith --pattern xclocsmith.rb --dir /tmp
cp /tmp/xclocsmith.rb <tap>/Formula/xclocsmith.rb
```

Then check it before anyone else does:

```bash
brew install --build-from-source <tap>/Formula/xclocsmith.rb
brew test xclocsmith
brew audit --strict --online xclocsmith
```

`brew test` runs the formula's own smoke test: it asserts `--version` matches the formula's version and checks a small catalog, so a tarball that was built for the wrong architecture or a formula pointing at the wrong release fails there rather than on a user's machine.

## Notes

- The binaries are ad-hoc signed by the linker, not Developer ID signed or notarized. Homebrew does not quarantine what it downloads, so this is fine through the tap; someone who downloads the tarball in a browser will meet Gatekeeper and need `xattr -d com.apple.quarantine`.
- The tarball is around 2.5 MB. There are no dependencies to resolve — that is the whole install.
