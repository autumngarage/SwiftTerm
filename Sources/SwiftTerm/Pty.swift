//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

import Foundation
#if !os(iOS) && !os(tvOS) && !os(Windows)

/**
 * APIs to assist in controlling a Unix pseudo-terminal from Swift.
 *
 *This provides a wrapper for
 * the libc `forkpty`API in the form of `fork(andExec:args:env:desiredWindowSize:` method,
 * `setWinSize` and `availableBytes`
 */
public class PseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    /// Serializes every SwiftTerm PTY allocation through the point where each
    /// parent-owned endpoint is close-on-exec. A later terminal can therefore
    /// never fork while an older terminal's descriptor is still inheritable.
    ///
    /// The child side of `fork` must never touch this inherited locked object:
    /// it uses raw C calls through `posix_spawn`/`execve`/`_exit`, while only
    /// the parent and failure branches unlock it explicitly.
    private static let descriptorCreationLock = NSLock()

    /// Opens a PTY pair whose parent-owned endpoints cannot cross an exec
    /// boundary unless a spawner explicitly maps them for its child.
    static func openPseudoTerminal() throws -> (master: Int32, slave: Int32) {
        descriptorCreationLock.lock()

        var master: Int32 = -1
        var slave: Int32 = -1
        let result = openpty(&master, &slave, nil, nil, nil)
        guard result == 0 else {
            let errorCode = errno
            descriptorCreationLock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }

        if let errorCode = closeOnExecError(for: master)
            ?? closeOnExecError(for: slave)
        {
            close(master)
            close(slave)
            descriptorCreationLock.unlock()
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }

        descriptorCreationLock.unlock()
        return (master, slave)
    }

    /// Preserve all descriptor flags while requiring `FD_CLOEXEC`. Returning
    /// the captured errno lets callers close every partially-created endpoint
    /// before they expose an unsafe PTY to the rest of the process.
    private static func closeOnExecError(for descriptor: Int32) -> Int32? {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1 else { return errno }
        guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1 else {
            return errno
        }
        return nil
    }
    
#if os(macOS)
    /// Turns the forked child's exec into one that keeps only its terminal.
    ///
    /// `fork` duplicates every descriptor the host holds, and `execve` keeps
    /// all of them that are not close-on-exec. The host cannot mark them all:
    /// Darwin has no `pipe2(O_CLOEXEC)` or `SOCK_CLOEXEC`, so a descriptor
    /// another thread is creating is inheritable until its owner flags it, and
    /// much host code never does. A shell that inherited a pipe's writer holds
    /// it for as long as it lives, so that pipe's reader never sees EOF.
    ///
    /// `POSIX_SPAWN_SETEXEC` makes `posix_spawn` replace the calling process
    /// as `execve` would, and `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every
    /// descriptor its file actions do not name. The actions name only 0, 1
    /// and 2, which `forkpty` has already made the PTY; the controlling
    /// terminal and session are properties of the process, not of a
    /// descriptor, and survive the exec unchanged.
    ///
    /// Built in the parent: the child of a multithreaded process may run only
    /// async-signal-safe code, so it must not allocate.
    private struct TerminalExecBoundary {
        let attributes: UnsafeMutablePointer<posix_spawnattr_t?>
        let fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>

        /// nil, with `errno` set, when the attributes cannot be built.
        static func make() -> TerminalExecBoundary? {
            let attributes = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
            let fileActions = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
            let attributesResult = posix_spawnattr_init(attributes)
            guard attributesResult == 0 else {
                attributes.deallocate()
                fileActions.deallocate()
                errno = attributesResult
                return nil
            }
            let actionsResult = posix_spawn_file_actions_init(fileActions)
            guard actionsResult == 0 else {
                posix_spawnattr_destroy(attributes)
                attributes.deallocate()
                fileActions.deallocate()
                errno = actionsResult
                return nil
            }
            let boundary = TerminalExecBoundary(attributes: attributes, fileActions: fileActions)
            var result = posix_spawnattr_setflags(
                attributes,
                Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
            for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where result == 0 {
                result = posix_spawn_file_actions_addinherit_np(fileActions, descriptor)
            }
            guard result == 0 else {
                boundary.destroy()
                errno = result
                return nil
            }
            return boundary
        }

        func destroy() {
            posix_spawn_file_actions_destroy(fileActions)
            posix_spawnattr_destroy(attributes)
            fileActions.deallocate()
            attributes.deallocate()
        }
    }
#endif

    /* Taken from Swift's StdLib: https://github.com/apple/swift/blob/master/stdlib/private/SwiftPrivate/SwiftPrivate.swift */
    static func scan<
      S : Sequence, U
    >(_ seq: S, _ initial: U, _ combine: (U, S.Iterator.Element) -> U) -> [U] {
      var result: [U] = []
      result.reserveCapacity(seq.underestimatedCount)
      var runningResult = initial
      for element in seq {
        runningResult = combine(runningResult, element)
        result.append(runningResult)
      }
      return result
    }

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    /**
     * This method both forks and executes the provided command under a Pseudo Terminal (pty)
     * - Parameter andExec: the name of the executable to run
     * - Parameter args: arguments to be passed to the executable
     * - Parameter env: the environment variables for the child process
     * - Parameter desiredWindowSize: the window size that will be set on the pseudo terminal.
     *
     * - Returns: nil on error, or a tuple containing the process ID, and the file descriptor to the primary side of the newly created pseudo-terminal.
     */
    public static func fork (andExec: String, args: [String], env: [String], currentDirectory: String? = nil, desiredWindowSize: inout winsize) -> (pid: pid_t, masterFd: Int32)?
    {
        guard let cArgs = allocateCStringArray(args) else {
            return nil
        }
        guard let cEnv = allocateCStringArray(env) else {
            freeCStringArray(cArgs)
            return nil
        }
        guard let cExecutable = strdup(andExec) else {
            freeCStringArray(cEnv)
            freeCStringArray(cArgs)
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicatedCurrentDirectory = strdup(currentDirectory) else {
                free(cExecutable)
                freeCStringArray(cEnv)
                freeCStringArray(cArgs)
                return nil
            }
            cCurrentDirectory = duplicatedCurrentDirectory
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

#if os(macOS)
        guard let execBoundary = TerminalExecBoundary.make() else {
            return nil
        }
        defer { execBoundary.destroy() }
        // Plain pointers, so the child reads no Swift aggregate after fork.
        let spawnAttributes = execBoundary.attributes
        let spawnFileActions = execBoundary.fileActions
#endif

        var master: Int32 = 0
        
        // Serialise PTY allocation through the point where the parent-owned
        // master is close-on-exec, so a second terminal cannot fork while this
        // one's descriptor is still inheritable. The child never touches this
        // lock: from here it runs only raw C calls to posix_spawn/execve/_exit.
        descriptorCreationLock.lock()
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            descriptorCreationLock.unlock()
            return nil
        }
        if pid == 0 {
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }
            
#if os(macOS)
            // Exec keeping only the terminal (see `TerminalExecBoundary`).
            // Returns only on failure.
            _ = posix_spawn(nil, cExecutable, spawnFileActions, spawnAttributes, cArgs.base, cEnv.base)
#else
            _ = execve(cExecutable, cArgs.base, cEnv.base)
#endif
            _exit(127)
        }
        if let errorCode = closeOnExecError(for: master) {
            // Never hand back an inheritable PTY. The child already exists, so
            // fail closed: terminate and reap it before another launch can take
            // the lock. The `defer` above still frees the C strings.
            close(master)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            descriptorCreationLock.unlock()
            errno = errorCode
            return nil
        }
        descriptorCreationLock.unlock()
        return (pid, master)
    }
    
    /**
     * Sets the window size of the underlying pseudo terminal.
     * - Parameter masterPtyDescriptor: a pseudo-terminal master file descriptor, as returned by fork(andExec:)
     * - Returns: the value from calling the ioctl
     */
    public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32
    {
#if os(macOS)
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
#else
	return ioctl(masterPtyDescriptor, UInt(TIOCSWINSZ), &windowSize)
#endif
    }
    
    /**
     * Returns the number of available bytes to be read from the file descriptor
     */
    public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32)
    {
        var size: Int32 = 0
        let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
        return (status, size)
    }
}
#endif
