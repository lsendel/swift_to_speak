# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceFlow AI is a real-time voice AI assistant platform with sub-100ms latency, supporting iOS, macOS, and Windows clients. The system uses multiple speech providers (Deepgram, Google, Azure) with automatic failover and leverages xAI's Grok for conversational AI.

## Common Development Commands

### Node.js Backend
```bash
# Install dependencies
npm install

# Development
npm run dev        # Start development server with hot reload (port 3001)
npm run build      # Compile TypeScript to JavaScript
npm run start      # Start production server

# Testing & Quality
npm run test       # Run Jest tests with coverage
npm run test:watch # Run tests in watch mode
npm run lint       # Run ESLint on TypeScript files
npm run type-check # TypeScript type checking without emit
```

### Python Backend
```bash
# Install dependencies
pip install -r requirements.txt

# Development
uvicorn main:app --reload --port 3002  # Start FastAPI server

# Testing & Quality
pytest --cov                            # Run tests with coverage
black .                                 # Format code
flake8                                  # Lint Python code
mypy .                                  # Type checking
```

### iOS/macOS Development
```bash
# Build Swift package
swift build

# Run tests
swift test

# Open in Xcode
open ios/VoiceFlowAI.xcodeproj
```

### Docker Services
```bash
# Start all services
docker-compose up -d

# Start specific service
docker-compose up node-backend python-backend redis postgres

# View logs
docker-compose logs -f [service-name]

# Stop services
docker-compose down
```

## High-Level Architecture

### Service Communication Flow
1. **Client → WebSocket Gateway**: iOS/Desktop clients connect via WebSocket to Node.js backend (port 3001)
2. **Gateway → Speech Providers**: Audio streams are sent to primary provider (Deepgram), with automatic fallback to Google/Azure
3. **Gateway → AI Processing**: Transcribed text goes to xAI Grok for response generation
4. **Gateway → TTS**: AI responses are converted to speech via ElevenLabs (primary) or fallbacks
5. **Gateway → Client**: Audio stream returned to client with <100ms total latency

### Core Services

#### Node.js Backend (`backend/node/`)
- **Framework**: NestJS with TypeScript
- **Entry Point**: `src/index.ts`
- **WebSocket Gateway**: `src/gateways/voice.gateway.ts` - Handles real-time voice streaming
- **Provider Service**: `src/services/provider.service.ts` - Manages speech provider failover logic
- **Key Dependencies**: Socket.io for WebSockets, Redis for pub/sub, PostgreSQL for persistence

#### Python Backend (`backend/python/`)
- **Framework**: FastAPI for ML processing and additional APIs
- **Entry Point**: `main.py`
- **Purpose**: Handles ML model inference, audio processing, and batch operations
- **Key Libraries**: Deepgram SDK, Google Cloud Speech, Azure Cognitive Services

#### iOS Client (`ios/`)
- **Swift Package**: Defined in `Package.swift`
- **Voice Service**: `Sources/VoiceFlowAI/VoiceService.swift` - Core audio capture and streaming
- **Dependencies**: SocketIO client, AudioKit for audio processing, Alamofire for networking

### Provider Failover Strategy
The system implements intelligent failover across multiple providers:
1. **Primary Path**: Deepgram STT → xAI Grok → ElevenLabs TTS
2. **Fallback Triggers**: Timeout (>500ms), error response, rate limiting
3. **Provider Priority**: Configurable per service in environment variables
4. **Circuit Breaker**: Temporarily disables failing providers to prevent cascading failures

### Database Schema
- **PostgreSQL**: User accounts, conversation history, preferences
- **Redis**: Active sessions, real-time metrics, provider health status
- **Vector DB** (future): Conversation embeddings for context retrieval

### Environment Configuration
Required API keys and service URLs are configured via environment variables:
- Speech services: `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`, `GOOGLE_CLOUD_API_KEY`, `AZURE_SPEECH_KEY`
- AI services: `XAI_API_KEY`, AWS credentials for Lex
- Infrastructure: `DATABASE_URL`, `REDIS_URL`, WebSocket ports

### Testing Strategy
- **Unit Tests**: Jest for Node.js, pytest for Python, Quick/Nimble for Swift
- **Integration Tests**: Test provider failover scenarios
- **Performance Tests**: Located in `tests/performance-tests.js`
- **Load Testing**: Simulate concurrent WebSocket connections

### Deployment
- **Container Orchestration**: Docker Compose for local development, Kubernetes (EKS) for production
- **Service Mesh**: Istio for inter-service communication
- **Monitoring**: Prometheus + Grafana for metrics, Jaeger for distributed tracing
- **CI/CD**: GitHub Actions for automated testing and deployment