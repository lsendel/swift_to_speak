// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceFlowAI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VoiceFlowAI",
            targets: ["VoiceFlowAI"]
        ),
        .executable(
            name: "VoiceFlowAIApp",
            targets: ["VoiceFlowAIApp"]
        )
    ],
    dependencies: [
        // WebSocket client
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
        
        // Audio processing
        .package(url: "https://github.com/AudioKit/AudioKit", from: "5.6.0"),
        
        // Networking
        .package(url: "https://github.com/Alamofire/Alamofire", from: "5.8.1"),
        
        // Async/Await utilities
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        
        // Logging
        .package(url: "https://github.com/apple/swift-log", from: "1.5.3"),
        
        // Testing
        .package(url: "https://github.com/Quick/Quick", from: "7.3.0"),
        .package(url: "https://github.com/Quick/Nimble", from: "13.1.0")
    ],
    targets: [
        .target(
            name: "VoiceFlowAI",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                .product(name: "AudioKit", package: "AudioKit"),
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/VoiceFlowAI"
        ),
        .executableTarget(
            name: "VoiceFlowAIApp",
            dependencies: ["VoiceFlowAI"],
            path: "Sources/VoiceFlowAIApp"
        ),
        .testTarget(
            name: "VoiceFlowAITests",
            dependencies: [
                "VoiceFlowAI",
                .product(name: "Quick", package: "Quick"),
                .product(name: "Nimble", package: "Nimble")
            ],
            path: "Tests/VoiceFlowAITests"
        )
    ]
)