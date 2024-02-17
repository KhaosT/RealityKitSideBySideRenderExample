//
//  SBSVideoExpApp.swift
//  SBSVideoExp
//
//  Created by Khaos Tian on 2/15/24.
//

import SwiftUI

@main
struct SBSVideoExpApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 320, height: 320)


        WindowGroup(id: "player") {
            PlayerView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1, height: 9/16, depth: 0.1, in: .meters)
    }
}
