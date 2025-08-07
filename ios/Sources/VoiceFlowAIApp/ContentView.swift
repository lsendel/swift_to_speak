import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voiceManager = VoiceManager()
    @State private var isRecording = false
    @State private var connectionStatus = "Disconnected"
    @State private var latencyText = "-- ms"
    @State private var showSettings = false
    @State private var animationScale: CGFloat = 1.0
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.07, green: 0.07, blue: 0.12),
                        Color(red: 0.1, green: 0.1, blue: 0.2)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 30) {
                    // Status Bar
                    HStack {
                        StatusIndicator(
                            title: "Connection",
                            value: connectionStatus,
                            isActive: voiceManager.isConnected
                        )
                        
                        Spacer()
                        
                        StatusIndicator(
                            title: "Latency",
                            value: latencyText,
                            isActive: voiceManager.latency < 100
                        )
                    }
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    // Transcript Display
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcript")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        ScrollView {
                            Text(voiceManager.transcript.isEmpty ? "Tap the microphone to start speaking..." : voiceManager.transcript)
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 15)
                                        .fill(Color.white.opacity(0.1))
                                )
                        }
                        .frame(height: 200)
                    }
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    // Recording Button
                    Button(action: toggleRecording) {
                        ZStack {
                            // Animated circles when recording
                            if isRecording {
                                Circle()
                                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                                    .scaleEffect(animationScale)
                                    .opacity(2 - Double(animationScale))
                                    .animation(
                                        Animation.easeOut(duration: 1)
                                            .repeatForever(autoreverses: false),
                                        value: animationScale
                                    )
                                
                                Circle()
                                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                                    .scaleEffect(animationScale * 0.8)
                                    .opacity(2 - Double(animationScale))
                                    .animation(
                                        Animation.easeOut(duration: 1)
                                            .delay(0.3)
                                            .repeatForever(autoreverses: false),
                                        value: animationScale
                                    )
                            }
                            
                            // Main button
                            Circle()
                                .fill(isRecording ? Color.red : Color.blue)
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Image(systemName: isRecording ? "mic.fill" : "mic")
                                        .font(.system(size: 40))
                                        .foregroundColor(.white)
                                )
                                .shadow(color: isRecording ? Color.red : Color.blue, radius: isRecording ? 20 : 10)
                        }
                    }
                    .scaleEffect(isRecording ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: isRecording)
                    
                    // Instructions
                    Text(isRecording ? "Listening..." : "Tap to speak")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 50)
                }
                .padding()
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .sheet(isPresented: $showSettings) {
                SettingsView(voiceManager: voiceManager)
            }
        }
        .onAppear {
            Task {
                await connectToServer()
            }
        }
        .onChange(of: isRecording) { newValue in
            if newValue {
                animationScale = 2.0
            } else {
                animationScale = 1.0
            }
        }
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        Task {
            do {
                try await voiceManager.startRecording()
                withAnimation {
                    isRecording = true
                }
            } catch {
                print("Failed to start recording: \(error)")
                // Show error alert
            }
        }
    }
    
    private func stopRecording() {
        voiceManager.stopRecording()
        withAnimation {
            isRecording = false
        }
    }
    
    private func connectToServer() async {
        do {
            connectionStatus = "Connecting..."
            try await voiceManager.connect(
                to: appState.serverEndpoint,
                token: appState.authToken
            )
            connectionStatus = "Connected"
            
            // Update latency display
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                latencyText = String(format: "%.0f ms", voiceManager.latency * 1000)
            }
        } catch {
            connectionStatus = "Failed"
            print("Connection failed: \(error)")
        }
    }
}

struct StatusIndicator: View {
    let title: String
    let value: String
    let isActive: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
            
            HStack(spacing: 5) {
                Circle()
                    .fill(isActive ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.1))
        )
    }
}

struct SettingsView: View {
    @ObservedObject var voiceManager: VoiceManager
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            Form {
                Section("Server Configuration") {
                    TextField("Endpoint", text: $appState.serverEndpoint)
                    TextField("Auth Token", text: $appState.authToken)
                }
                
                Section("Audio Quality") {
                    Picker("Quality Profile", selection: $voiceManager.qualityProfile) {
                        Text("Premium").tag(0)
                        Text("Standard").tag(1)
                        Text("Economy").tag(2)
                    }
                }
                
                Section("Statistics") {
                    HStack {
                        Text("Current Latency")
                        Spacer()
                        Text("\(Int(voiceManager.latency * 1000)) ms")
                    }
                    
                    HStack {
                        Text("Network Quality")
                        Spacer()
                        Text(voiceManager.networkQuality)
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarItems(trailing: Button("Done") { dismiss() })
            #else
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppState())
    }
}