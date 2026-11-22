//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import SwiftUI

@main
struct RemoServerApp: App {
    @State private var controller = ServerController()

    var body: some Scene {
        Window("Remo Server", id: "main") {
            ContentView()
                .environment(controller)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandMenu("Server") {
                Button("Start") { controller.start() }
                    .keyboardShortcut("r")
                    .disabled(controller.state.isRunning || !controller.settings.problems.isEmpty)
                Button("Stop") { controller.stop() }
                    .keyboardShortcut(".")
                    .disabled(!controller.state.isRunning || controller.state == .stopping)
                Button("Restart") { controller.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!controller.state.isRunning || !controller.settings.problems.isEmpty)
            }
        }
    }
}
