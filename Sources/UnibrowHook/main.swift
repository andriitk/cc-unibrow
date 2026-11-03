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

    // Connect first: without the app there is nothing to look up.
    guard let fd = try? UnixSocket.connect(path: Paths.socketPath()) else { return nil }
    defer { close(fd) }

    // Session details for the cards that show them (requests, alerts and
    // "finished" notices): repository, and the process chain that leads to the app.
    guard let message = HookMessage.relayed(
        input: input,
        eventName: CommandLine.arguments.dropFirst().first,
        repository: { GitBranch.repository(containing: $0) },
        ancestors: { ProcessAncestry.candidates(of: getpid()) },
        // A risky Bash command gets a short, read-only impact note, looked
        // up within `CommandImpact.budget`; on any failure there is none.
        impact: { payload, root in CommandImpact.note(for: payload, projectRoot: root, probe: .live()) }
    ) else { return nil }
    let event = message.event

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
    //
    // An elicitation also has a deadline: Claude Code shows no dialog while
    // this hook runs, so after `answerDeadline` the relay prints nothing and
    // the dialog appears (closing the socket also drops the card).
    let parent = getppid()
    let started = Date()
    let deadline = event.answerDeadline
    let shouldGiveUp = {
        getppid() != parent || getppid() == 1
            || deadline.map { Date().timeIntervalSince(started) >= $0 } == true
    }
    guard let line = try? UnixSocket.readLine(from: fd, shouldGiveUp: shouldGiveUp),
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
