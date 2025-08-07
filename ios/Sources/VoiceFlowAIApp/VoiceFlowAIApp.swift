import SwiftUI

@main
struct VoiceFlowAIApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    setupApp()
                }
        }
    }
    
    private func setupApp() {
        // Configure app-wide settings
        print("VoiceFlowAI App Starting...")
    }
}

// Global app state
class AppState: ObservableObject {
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var serverEndpoint = "wss://localhost:3001"
    @Published var authToken = "demo-token"
}