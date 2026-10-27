// unibrow-hook — the relay Claude Code runs for every Unibrow hook event.
//
//   unibrow-hook <HookEventName>   (hook JSON on stdin)
//
// It forwards the event to the Unibrow app over a Unix socket. For
// `PermissionRequest` and `Elicitation` it waits for the user's answer and
// prints it in the format Claude Code expects.
//
// Golden rule: this process must never break a Claude Code session. Every
// failure (app not running, bad input, socket error) ends in exit 0 with no
// output, which makes Claude Code fall back to its normal terminal prompt.

import Darwin
import Foundation
import UnibrowCore

func relay() -> Data? {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = try? HookPayload(data: input) else { return nil }

    let eventName = CommandLine.arguments.dropFirst().first ?? payload.hookEventName ?? ""
    guard let event = HookEvent(rawValue: eventName) else { return nil }

    guard let fd = try? UnixSocket.connect(path: Paths.socketPath()) else { return nil }
    defer { close(fd) }

    // Session details for the cards that show them (requests, alerts and
    // "finished" notices): repository, and the process chain that leads to the app.
    let needsRepository = event.needsSessionDetails
    let repository = needsRepository ? payload.cwd.flatMap { GitBranch.repository(containing: $0) } : nil
    let message = HookMessage(
        event: event,
        payload: payload.raw,
        branch: repository?.branch,
        projectRoot: repository?.root,
        ancestorPIDs: needsRepository ? ProcessAncestry.candidates(of: getpid()) : nil,
        propertyOrder: event == .elicitation
            ? JSONKeyOrder.keys(in: input, at: ["requested_schema", "properties"])
            : nil
    )
    guard let frame = try? WireProtocol.frame(message),
          (try? UnixSocket.writeAll(frame, to: fd)) != nil
    else { return nil }

    guard event.expectsDecision else { return nil }

    // Blocks until the user decides. Claude Code may cancel this process at any
    // time (the user answered in the terminal, the session ended); the app then
    // sees the connection close and drops the request from the notch.
    //
    // Safety net: if our parent dies without killing us, we are re-parented to
    // launchd (PID 1). Nobody can read our answer any more, so exit and free
    // the request instead of waiting for the hook timeout.
    let parent = getppid()
    let isOrphaned = { getppid() != parent || getppid() == 1 }
    guard let line = try? UnixSocket.readLine(from: fd, shouldGiveUp: isOrphaned),
          let reply = try? WireProtocol.unframe(DecisionMessage.self, from: line),
          let output = HookOutput.output(for: event, reply.decision)
    else { return nil }

    return try? output.encoded()
}

if let output = relay() {
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
exit(0)
