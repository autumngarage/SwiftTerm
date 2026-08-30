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
    /// it uses raw C calls through `execve`/`_exit`, while only the parent and
    /// failure branches unlock it explicitly.
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

        var master: Int32 = 0
        
        // Serialise PTY allocation through the point where the parent-owned
        // master is close-on-exec, so a second terminal cannot fork while this
        // one's descriptor is still inheritable. The child never touches this
        // lock: from here it runs only raw C calls to execve/_exit.
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
            
            _ = execve(cExecutable, cArgs.base, cEnv.base)
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
