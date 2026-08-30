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

    /* Taken from Swift's StdLib: https://github.com/apple/swift/blob/master/stdlib/private/SwiftPrivate/SwiftPrivate.swift */
    static func withArrayOfCStrings<R>(
      _ args: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R
    ) -> R {
      let argsCounts = Array(args.map { $0.utf8.count + 1 })
      let argsOffsets = [ 0 ] + scan(argsCounts, 0, +)
      let argsBufferSize = argsOffsets.last!

      var argsBuffer: [UInt8] = []
      argsBuffer.reserveCapacity(argsBufferSize)
      for arg in args {
        argsBuffer.append(contentsOf: arg.utf8)
        argsBuffer.append(0)
      }

      return argsBuffer.withUnsafeMutableBufferPointer {
        (argsBuffer) in
        let ptr = UnsafeMutableRawPointer(argsBuffer.baseAddress!).bindMemory(
          to: CChar.self, capacity: argsBuffer.count)
        var cStrings: [UnsafeMutablePointer<CChar>?] = argsOffsets.map { ptr + $0 }
        cStrings[cStrings.count - 1] = nil
        return body(cStrings)
      }
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
        // Pre-compute ALL C strings before fork.
        // After fork, the child must avoid Swift runtime calls (String ops,
        // closures, Array allocation) because another thread may have held
        // an os_unfair_lock at fork time, leaving it permanently locked in
        // the child — causing "crashed on child side of fork pre-exec".

        let cExec = strdup(andExec)!
        let cDir = currentDirectory.map { strdup($0)! }

        // Build null-terminated C arrays for args and env
        var cArgs = args.map { strdup($0)! as UnsafeMutablePointer<CChar>? }
        cArgs.append(nil)
        var cEnv = env.map { strdup($0)! as UnsafeMutablePointer<CChar>? }
        cEnv.append(nil)

        var master: Int32 = 0

        descriptorCreationLock.lock()
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            let errorCode = errno
            descriptorCreationLock.unlock()
            // Clean up on fork failure
            free(cExec)
            cDir.map { free($0) }
            for p in cArgs { p.map { free($0) } }
            for p in cEnv { p.map { free($0) } }
            errno = errorCode
            return nil
        }
        if pid == 0 {
            // Child process — only raw C calls from here to execve
            if let dir = cDir { _ = chdir(dir) }
            execve(cExec, &cArgs, &cEnv)
            _exit(1) // execve failed
        }

        if let errorCode = closeOnExecError(for: master) {
            // Never return an inheritable PTY. The child already exists, so
            // fail closed by terminating and reaping it before another
            // SwiftTerm launch can acquire the descriptor-creation lock.
            close(master)
            _ = kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            descriptorCreationLock.unlock()

            free(cExec)
            cDir.map { free($0) }
            for p in cArgs { p.map { free($0) } }
            for p in cEnv { p.map { free($0) } }
            errno = errorCode
            return nil
        }
        descriptorCreationLock.unlock()

        // Parent — free the copies (child has execve'd, so its copies are gone)
        free(cExec)
        cDir.map { free($0) }
        for p in cArgs { p.map { free($0) } }
        for p in cEnv { p.map { free($0) } }

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
