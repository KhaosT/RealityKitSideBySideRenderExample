//
//  PlayerView.swift
//  SBSVideoExp
//
//  Created by Khaos Tian on 2/15/24.
//

import SwiftUI
import RealityKit

struct PlayerView: View {

    private let viewModel = VideoPlaybackViewModel()

    @State
    private var isReady: Bool = false

    @Environment(\.scenePhase)
    private var scenePhase

    var body: some View {
        RealityView { content in
            await viewModel.loadShaderMaterial()

            let entity = Entity()
            entity.name = "DisplaySurface"
            entity.components.set(
                ModelComponent(
                    mesh: .generatePlane(width: 1, height: 9/16, cornerRadius: 0.02),
                    materials: [
                        viewModel.surfaceMaterial!,
                    ]
                )
            )
            content.add(entity)

            isReady = true
        }
        .onChange(of: scenePhase, initial: true, {
            switch scenePhase {
            case .active:
                if isReady {
                    viewModel.play()
                }
            case .background:
                viewModel.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        })
        .onChange(of: isReady, {
            if isReady {
                viewModel.play()
            }
        })
    }
}
