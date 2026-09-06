//
// Source-control information for this SwiftTerm build.
//
// Upstream generates this file with a build-tool plugin that shells out to git
// during the build. That does not work for Vesper's fork, for two reasons.
//
// Xcode refuses to run a package's build-tool plugin without explicit
// validation, so an `xcodebuild` release build fails outright rather than
// prompting. And the plugin's answer depends on the git state of whatever
// checkout happens to be on disk, which for a dependency pinned by revision is
// both fixed and none of the build's business — a hermetic build should not
// consult a repository at all.
//
// The values are therefore stated rather than derived. They describe the base
// this fork carries, which is what a client asking XTVERSION wants to know:
// which emulator it is talking to, not which working copy compiled it.
//

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    /// The Git branch, if the build uses a branch checkout.
    public static let branch: String? = "vesper"

    /// The exact Git tag for the current commit, if one is available.
    ///
    /// The upstream release this fork is based on. `version` builds on it, so
    /// the two stay consistent with the derivation upstream documents: the tag
    /// when there is one, the commit otherwise.
    public static let tag: String? = "v1.20.0"

    /// The full Git commit identifier, if one is available.
    ///
    /// Deliberately absent: the fork is consumed by revision, so the consuming
    /// package's pin is the authority on which commit this is, and duplicating
    /// it here would need editing on every rebase and would be wrong the moment
    /// someone forgot.
    public static let commit: String? = nil

    /// Whether the repository had uncommitted changes during the build.
    ///
    /// Always `nil`: a pinned dependency is never built from a dirty worktree
    /// in a release, and asking would mean consulting git during the build.
    public static let hasUncommittedChanges: Bool? = nil

    /// A value suitable for display in logs and diagnostic output.
    ///
    /// Names the upstream release this fork is based on, plus the fork itself,
    /// so a client can tell both which emulator behaviour to expect and that it
    /// is not stock upstream.
    public static let version: String = "v1.20.0+vesper"
}
