import Foundation
import MusicMCPCore

// Launcher only. Everything testable lives in MusicMCPCore, which the test target
// imports; an executable target cannot be imported.
await MusicMCPServer.run()
