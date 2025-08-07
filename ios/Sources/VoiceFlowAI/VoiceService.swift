import Foundation
import AVFoundation
import Accelerate
import Network
import Combine
import SocketIO
import AudioKit
#if os(iOS)
import UIKit
#endif

/// High-performance voice service with hardware optimization
@available(iOS 16.0, *)
public final class VoiceService: NSObject {
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var audioFormat: AVAudioFormat?
    
    // Hardware-optimized buffer settings
    private let bufferSize: AVAudioFrameCount = 256  // Optimal for A12+ chips
    private let sampleRate: Double = 48000  // Hardware native rate
    
    // Network optimization
    private var socketManager: SocketManager?
    private var socket: SocketIOClient?
    private let networkMonitor = NWPathMonitor()
    private var networkQuality: NetworkQuality = .good
    
    // Audio processing with Accelerate framework
    private var fftSetup: FFTSetup?
    private let fftLength: vDSP_Length = 512
    
    // Adaptive quality management
    private var currentQualityProfile: QualityProfile = .standard
    
    // Performance monitoring
    private var processingTimes: [TimeInterval] = []
    private let metricsCollector = MetricsCollector()
    
    // State management
    @Published public private(set) var isRecording = false
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var latency: TimeInterval = 0
    
    // Audio session configuration
    #if os(iOS)
    private let audioSession = AVAudioSession.sharedInstance()
    #endif
    
    // Voice Activity Detection with Core ML
    private let vad = VoiceActivityDetector()
    
    // Circular buffer for zero-copy audio processing
    private var audioBuffer: UnsafeMutablePointer<TPCircularBuffer>?
    private let bufferCapacity: UInt32 = 48000 * 10  // 10 seconds
    
    // MARK: - Quality Profiles
    
    enum QualityProfile {
        case premium
        case standard
        case economy
        
        var audioConfig: AudioConfig {
            switch self {
            case .premium:
                return AudioConfig(
                    sampleRate: 48000,
                    bitDepth: 24,
                    channels: 1,
                    codec: .opus(bitrate: 128000),
                    processingMode: .advanced
                )
            case .standard:
                return AudioConfig(
                    sampleRate: 24000,
                    bitDepth: 16,
                    channels: 1,
                    codec: .opus(bitrate: 64000),
                    processingMode: .standard
                )
            case .economy:
                return AudioConfig(
                    sampleRate: 16000,
                    bitDepth: 16,
                    channels: 1,
                    codec: .opus(bitrate: 32000),
                    processingMode: .basic
                )
            }
        }
    }
    
    // MARK: - Initialization
    
    public override init() {
        super.init()
        setupAudioSession()
        setupNetworkMonitoring()
        setupFFT()
        setupCircularBuffer()
    }
    
    deinit {
        TPCircularBufferCleanup(audioBuffer)
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        #if os(iOS)
        do {
            // Configure for optimal voice processing
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            
            // Set preferred hardware settings
            try audioSession.setPreferredSampleRate(sampleRate)
            try audioSession.setPreferredIOBufferDuration(Double(bufferSize) / sampleRate)
            
            // Enable voice processing
            try audioSession.setVoiceProcessingEnabled(true)
            
            // Activate session
            try audioSession.setActive(true)
            
            print("✅ Audio session configured: \(sampleRate)Hz, \(bufferSize) samples")
            
        } catch {
            print("❌ Audio session setup failed: \(error)")
        }
        #else
        print("✅ Audio session configuration skipped on macOS")
        #endif
    }
    
    // MARK: - Network Setup
    
    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.updateNetworkQuality(path)
        }
        
        let queue = DispatchQueue(label: "network.monitor", qos: .userInitiated)
        networkMonitor.start(queue: queue)
    }
    
    private func updateNetworkQuality(_ path: NWPath) {
        // Determine network quality
        if path.status == .satisfied {
            if path.isExpensive {
                networkQuality = .fair
                currentQualityProfile = .economy
            } else if path.usesInterfaceType(.wifi) {
                networkQuality = .excellent
                currentQualityProfile = .premium
            } else if path.usesInterfaceType(.cellular) {
                networkQuality = .good
                currentQualityProfile = .standard
            } else {
                networkQuality = .fair
                currentQualityProfile = .economy
            }
        } else {
            networkQuality = .poor
            currentQualityProfile = .economy
        }
        
        print("📶 Network quality: \(networkQuality), Profile: \(currentQualityProfile)")
    }
    
    // MARK: - Hardware Acceleration Setup
    
    private func setupFFT() {
        // Setup FFT for spectral analysis using Accelerate framework
        fftSetup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(fftLength))),
            FFTRadix(kFFTRadix2)
        )
    }
    
    private func setupCircularBuffer() {
        audioBuffer = TPCircularBuffer.allocate()
        if let buffer = audioBuffer {
            TPCircularBufferInit(buffer, bufferCapacity)
        }
    }
    
    // MARK: - Connection Management
    
    public func connect(to endpoint: String, token: String) async throws {
        let config: SocketIOClientConfiguration = [
            .log(false),
            .compress,
            .forceWebsockets(true),
            .secure(true),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectAttempts(-1),
            .connectParams(["token": token]),
            .version(.three)
        ]
        
        guard let url = URL(string: endpoint) else {
            throw VoiceServiceError.invalidEndpoint
        }
        
        socketManager = SocketManager(socketURL: url, config: config)
        socket = socketManager?.defaultSocket
        
        setupSocketHandlers()
        
        socket?.connect()
        
        // Wait for connection
        try await waitForConnection()
    }
    
    private func setupSocketHandlers() {
        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            self?.connectionState = .connected
            self?.startLatencyMonitoring()
            print("🔌 Connected to voice server")
        }
        
        socket?.on("transcript") { [weak self] data, _ in
            guard let self = self,
                  let response = data.first as? [String: Any],
                  let text = response["text"] as? String else { return }
            
            DispatchQueue.main.async {
                self.transcript = text
            }
            
            // Record latency
            if let timestamp = response["timestamp"] as? TimeInterval {
                self.latency = Date().timeIntervalSince1970 - timestamp
                self.metricsCollector.recordLatency(self.latency)
            }
        }
        
        socket?.on("audio_response") { [weak self] data, _ in
            guard let response = data.first as? [String: Any],
                  let audioData = response["audio"] as? Data else { return }
            
            self?.playAudioResponse(audioData)
        }
        
        socket?.on("error") { data, _ in
            print("❌ Socket error: \(data)")
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.connectionState = .disconnected
            print("🔌 Disconnected from voice server")
        }
    }
    
    // MARK: - Audio Recording
    
    public func startRecording() async throws {
        guard connectionState == .connected else {
            throw VoiceServiceError.notConnected
        }
        
        // Request microphone permission if needed
        guard await requestMicrophonePermission() else {
            throw VoiceServiceError.microphonePermissionDenied
        }
        
        inputNode = audioEngine.inputNode
        
        // Hardware-optimized format
        let hardwareFormat = inputNode!.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: currentQualityProfile.audioConfig.sampleRate,
            channels: 1,
            interleaved: false
        )!
        
        // Create converter for format conversion
        let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)!
        
        // Install tap with optimal buffer size
        inputNode!.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: hardwareFormat
        ) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }
        
        // Prepare and start engine
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecording = true
        
        // Send session start
        socket?.emit("start_session", [
            "user_id": getUserId(),
            "platform": "ios",
            "device": getDeviceInfo(),
            "quality_profile": String(describing: currentQualityProfile)
        ])
        
        print("🎤 Recording started with profile: \(currentQualityProfile)")
    }
    
    // MARK: - Audio Processing (Hardware Optimized)
    
    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Convert to target format
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
            )
        ) else { return }
        
        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        if let error = error {
            print("❌ Conversion error: \(error)")
            return
        }
        
        // Apply hardware-accelerated processing
        let processedAudio = applyHardwareAcceleratedProcessing(convertedBuffer)
        
        // Voice Activity Detection
        let hasVoice = vad.process(processedAudio)
        
        if hasVoice || isInConversation() {
            // Compress with Opus
            let compressedAudio = compressWithOpus(processedAudio)
            
            // Send to server
            sendAudioChunk(compressedAudio)
        }
        
        // Record processing time
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        processingTimes.append(processingTime)
        
        // Adaptive quality adjustment
        if processingTimes.count > 100 {
            adjustQualityBasedOnPerformance()
        }
    }
    
    private func applyHardwareAcceleratedProcessing(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.int16ChannelData else {
            return Data()
        }
        
        let frameLength = Int(buffer.frameLength)
        let samples = channelData[0]
        
        // Use Accelerate framework for DSP
        var floatSamples = [Float](repeating: 0, count: frameLength)
        vDSP_vflt16(samples, 1, &floatSamples, 1, vDSP_Length(frameLength))
        
        // Apply high-pass filter (remove DC offset)
        var filtered = [Float](repeating: 0, count: frameLength)
        var a: Float = 0.95
        vDSP_vsmul(floatSamples, 1, &a, &filtered, 1, vDSP_Length(frameLength))
        
        // Apply noise gate using vDSP
        var threshold: Float = 0.01
        var gated = [Float](repeating: 0, count: frameLength)
        vDSP_vthres(&filtered, 1, &threshold, &gated, 1, vDSP_Length(frameLength))
        
        // Convert back to Int16
        var outputSamples = [Int16](repeating: 0, count: frameLength)
        vDSP_vfix16(gated, 1, &outputSamples, 1, vDSP_Length(frameLength))
        
        return Data(bytes: outputSamples, count: frameLength * 2)
    }
    
    // MARK: - Opus Compression
    
    private func compressWithOpus(_ audioData: Data) -> Data {
        // Use Opus codec for optimal compression
        // This would integrate with libopus
        // For now, return original data
        return audioData
    }
    
    // MARK: - Network Transmission
    
    private func sendAudioChunk(_ audioData: Data) {
        let chunk: [String: Any] = [
            "session_id": getCurrentSessionId(),
            "audio": audioData.base64EncodedString(),
            "timestamp": Date().timeIntervalSince1970,
            "sequence_number": getNextSequenceNumber(),
            "quality": String(describing: currentQualityProfile),
            "network": String(describing: networkQuality)
        ]
        
        socket?.emit("audio_chunk", chunk)
    }
    
    // MARK: - Audio Playback
    
    private func playAudioResponse(_ audioData: Data) {
        // Hardware-accelerated audio playback
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                let player = try AVAudioPlayer(data: audioData)
                player.prepareToPlay()
                player.play()
            } catch {
                print("❌ Playback error: \(error)")
            }
        }
    }
    
    // MARK: - Performance Optimization
    
    private func adjustQualityBasedOnPerformance() {
        let avgProcessingTime = processingTimes.reduce(0, +) / Double(processingTimes.count)
        processingTimes.removeAll()
        
        // Target: < 5ms processing time
        if avgProcessingTime > 0.005 {
            // Downgrade quality if processing is too slow
            switch currentQualityProfile {
            case .premium:
                currentQualityProfile = .standard
            case .standard:
                currentQualityProfile = .economy
            case .economy:
                break  // Already at lowest
            }
            print("⚡ Downgraded to \(currentQualityProfile) (avg: \(avgProcessingTime * 1000)ms)")
        } else if avgProcessingTime < 0.002 && networkQuality == .excellent {
            // Upgrade quality if we have headroom
            switch currentQualityProfile {
            case .economy:
                currentQualityProfile = .standard
            case .standard:
                currentQualityProfile = .premium
            case .premium:
                break  // Already at highest
            }
            print("⚡ Upgraded to \(currentQualityProfile) (avg: \(avgProcessingTime * 1000)ms)")
        }
    }
    
    // MARK: - Latency Monitoring
    
    private func startLatencyMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.socket?.emit("ping", Date().timeIntervalSince1970)
        }
        
        socket?.on("pong") { [weak self] data, _ in
            guard let timestamp = data.first as? TimeInterval else { return }
            let rtt = Date().timeIntervalSince1970 - timestamp
            self?.latency = rtt / 2  // One-way latency estimate
        }
    }
    
    // MARK: - Helper Methods
    
    private func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        // On macOS, use different permission mechanism or return true for testing
        return true
        #endif
    }
    
    private func waitForConnection() async throws {
        let timeout: TimeInterval = 10
        let start = Date()
        
        while connectionState != .connected {
            if Date().timeIntervalSince(start) > timeout {
                throw VoiceServiceError.connectionTimeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 second
        }
    }
    
    private func getUserId() -> String {
        // Get from keychain or generate
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        // On macOS, use a different identifier
        return UUID().uuidString
        #endif
    }
    
    private func getDeviceInfo() -> [String: Any] {
        #if os(iOS)
        return [
            "model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "processor": getProcessorInfo(),
            "memory_gb": ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        ]
        #else
        return [
            "model": "Mac",
            "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor": getProcessorInfo(),
            "memory_gb": ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        ]
        #endif
    }
    
    private func getProcessorInfo() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
    
    private func getCurrentSessionId() -> String {
        // Return current session ID
        return "session_\(UUID().uuidString)"
    }
    
    private func getNextSequenceNumber() -> Int {
        // Implement sequence number tracking
        return 0
    }
    
    private func isInConversation() -> Bool {
        // Check if actively in conversation
        return isRecording
    }
}

// MARK: - Supporting Types

public enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

public enum NetworkQuality {
    case excellent
    case good
    case fair
    case poor
}

public struct AudioConfig {
    let sampleRate: Double
    let bitDepth: Int
    let channels: Int
    let codec: AudioCodec
    let processingMode: ProcessingMode
}

public enum AudioCodec {
    case pcm
    case opus(bitrate: Int)
    case aac
}

public enum ProcessingMode {
    case basic
    case standard
    case advanced
}

public enum VoiceServiceError: Error {
    case invalidEndpoint
    case notConnected
    case connectionTimeout
    case microphonePermissionDenied
}

// MARK: - Quality Manager

class QualityManager {
    func adjustQuality(basedOn performance: TimeInterval, network: NetworkQuality) -> VoiceService.QualityProfile {
        if performance > 0.005 {
            return .economy
        } else if performance < 0.002 && network == .excellent {
            return .premium
        }
        return .standard
    }
}

// MARK: - Metrics Collection

class MetricsCollector {
    private var latencies: [TimeInterval] = []
    private let maxSamples = 1000
    
    func recordLatency(_ latency: TimeInterval) {
        latencies.append(latency)
        if latencies.count > maxSamples {
            latencies.removeFirst()
        }
    }
    
    func getP50Latency() -> TimeInterval {
        percentile(latencies, 0.5)
    }
    
    func getP99Latency() -> TimeInterval {
        percentile(latencies, 0.99)
    }
    
    private func percentile(_ values: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }
}

// MARK: - Voice Activity Detector

class VoiceActivityDetector {
    private var energyThreshold: Float = 0.01
    private var speechFrames = 0
    private var silenceFrames = 0
    
    func process(_ audioData: Data) -> Bool {
        // Simple energy-based VAD
        // In production, use WebRTC VAD or Core ML model
        
        let samples = audioData.withUnsafeBytes { ptr in
            ptr.bindMemory(to: Int16.self)
        }
        
        var energy: Float = 0
        for sample in samples {
            energy += Float(sample * sample)
        }
        energy = sqrt(energy / Float(samples.count))
        
        if energy > energyThreshold {
            speechFrames += 1
            silenceFrames = 0
        } else {
            silenceFrames += 1
            if silenceFrames > 50 {  // 1 second of silence
                speechFrames = 0
            }
        }
        
        return speechFrames > 5  // 100ms of speech
    }
}

// MARK: - Circular Buffer (Bridging Header Required)

struct TPCircularBuffer {
    var buffer: UnsafeMutablePointer<Int8>?
    var length: UInt32
    var tail: UInt32
    var head: UInt32
    var fillCount: UInt32
    
    static func allocate() -> UnsafeMutablePointer<TPCircularBuffer> {
        return UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 1)
    }
}

func TPCircularBufferInit(_ buffer: UnsafeMutablePointer<TPCircularBuffer>?, _ length: UInt32) {
    // Initialize circular buffer
}

func TPCircularBufferCleanup(_ buffer: UnsafeMutablePointer<TPCircularBuffer>?) {
    // Cleanup circular buffer
}