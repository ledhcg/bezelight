import Foundation
import BezelightAgents

// bezelight-hook: forwards what an agent's hook reports to the Bezelight app.
// Never fails and never talks to stderr: a missing app must not disturb the agent.
let paths = BezelightPaths.current()
let cli = HookCLI(
    arguments: CommandLine.arguments,
    readInput: { BoundedInput.readAll() },
    now: { Int64(Date().timeIntervalSince1970 * 1000) },
    agentPID: { ProcessTree.agentPID() },
    send: { DatagramSender.send($0, toSocketAt: paths.socket.path) })
// A closed stdout (the agent gave up waiting) must not kill us with SIGPIPE or raise an exception.
signal(SIGPIPE, SIG_IGN)
let output = Array(cli.run().utf8)
_ = output.withUnsafeBufferPointer { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
exit(0)
