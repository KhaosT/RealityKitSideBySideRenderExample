//
//  ContentView.swift
//  SBSVideoExp
//
//  Created by Khaos Tian on 2/15/24.
//

import SwiftUI
import RealityKit

struct ContentView: View {

    @Environment(\.openWindow)
    private var openWindow

    var body: some View {
        VStack {
            Button("Open Player") {
                openWindow(id: "player")
            }
        }
        .padding()
    }
}
