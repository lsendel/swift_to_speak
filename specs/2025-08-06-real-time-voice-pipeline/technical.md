# Technical Specification: Real-Time Voice Processing Pipeline

## Architecture Details

### System Design

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   iOS App    │     │  macOS App   │     │ Windows App  │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │                     │                     │
       └─────────────────────┴─────────────────────┘
                             │
                    WebSocket (TLS 1.3)
                             │
                   ┌─────────▼──────────┐
                   │  WebSocket Gateway │
                   │   (AWS API GW)     │
                   └─────────┬──────────┘
                             │
           ┌─────────────────┴─────────────────┐
           │                                   │
    ┌──────▼──────┐                   ┌────────▼────────┐
    │   Pipeline   │                   │    Metrics      │
    │ Orchestrator │◄──────────────────┤   Collector     │
    └──────┬──────┘                   └─────────────────┘
           │
           ├──────────────┬──────────────┬──────────────┐
           │              │              │              │
    ┌──────▼──────┐ ┌─────▼──────┐ ┌────▼──────┐ ┌─────▼──────┐
    │   Audio     │ │    STT     │ │    AI     │ │    TTS     │
    │  Processor  │ │  Service   │ │  Service  │ │  Service   │
    └─────────────┘ └────────────┘ └───────────┘ └────────────┘
           │              │              │              │
    ┌──────▼──────────────▼──────────────▼──────────────▼──────┐
    │                     Provider Router                       │
    │  (Deepgram | Google | Azure) (xAI) (ElevenLabs | Azure)  │
    └───────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Audio Capture** (Client)
   - Capture 16-bit PCM audio at 16kHz
   - Apply client-side VAD for efficiency
   - Buffer 20ms frames (320 samples)
   - Compress with Opus codec (optional)

2. **WebSocket Transmission**
   - Establish secure WebSocket connection
   - Send binary audio frames
   - Receive JSON control messages
   - Handle reconnection with exponential backoff

3. **Pipeline Processing** (Server)
   ```javascript
   // Parallel processing streams
   async function processPipeline(audioStream) {
     const [transcript, context] = await Promise.all([
       sttService.transcribe(audioStream),
       contextManager.getContext(sessionId)
     ]);
     
     const aiResponse = await aiService.generate(transcript, context);
     const audioResponse = await ttsService.synthesize(aiResponse);
     
     return audioResponse;
   }
   ```

4. **Provider Routing**
   ```typescript
   class ProviderRouter {
     async route(request: SpeechRequest): Promise<SpeechResponse> {
       const providers = this.getHealthyProviders(request.type);
       
       for (const provider of providers) {
         try {
           return await this.executeWithTimeout(provider, request, 500);
         } catch (error) {
           this.recordFailure(provider, error);
           continue;
         }
       }
       
       throw new Error('All providers failed');
     }
   }
   ```

### Audio Processing Pipeline

```typescript
interface AudioPipeline {
  // Input processing
  preprocess(audio: Int16Array): Float32Array {
    // Normalize to [-1, 1]
    // Apply high-pass filter (80Hz)
    // Noise suppression (Speex)
    return processed;
  }
  
  // Voice Activity Detection
  detectVoice(audio: Float32Array): boolean {
    // WebRTC VAD algorithm
    // Energy-based detection
    // Zero-crossing rate
    return hasVoice;
  }
  
  // Streaming chunker
  chunk(audio: Float32Array): AudioChunk[] {
    // 20ms frames for real-time
    // 100ms chunks for STT
    // Overlap for continuity
    return chunks;
  }
}
```

### WebSocket Protocol

```typescript
// Client -> Server
interface ClientMessage {
  type: 'audio' | 'control';
  sessionId: string;
  sequenceNumber: number;
  timestamp: number;
  data: ArrayBuffer | ControlData;
}

// Server -> Client
interface ServerMessage {
  type: 'transcript' | 'audio' | 'status';
  sessionId: string;
  sequenceNumber: number;
  timestamp: number;
  data: TranscriptData | ArrayBuffer | StatusData;
}

// Transcript updates
interface TranscriptData {
  text: string;
  isFinal: boolean;
  confidence: number;
  words?: WordTiming[];
}

// Audio response
interface AudioData {
  format: 'pcm' | 'opus';
  sampleRate: number;
  channels: number;
  data: ArrayBuffer;
}
```

### State Management

```typescript
class SessionState {
  private state: Map<string, Session> = new Map();
  
  async createSession(userId: string): Promise<Session> {
    const session = {
      id: generateId(),
      userId,
      startTime: Date.now(),
      audioBuffer: new RingBuffer(16000 * 10), // 10 seconds
      transcript: [],
      context: [],
      providers: {
        stt: 'deepgram',
        tts: 'elevenlabs',
        ai: 'xai'
      },
      metrics: {
        latency: [],
        quality: [],
        cost: 0
      }
    };
    
    await this.redis.setex(
      `session:${session.id}`,
      3600, // 1 hour TTL
      JSON.stringify(session)
    );
    
    return session;
  }
}
```

### Provider Integration

#### Deepgram STT Integration
```typescript
class DeepgramProvider implements STTProvider {
  async connect(sessionId: string): Promise<WebSocket> {
    const ws = new WebSocket(
      'wss://api.deepgram.com/v1/listen?' +
      'model=nova-2&' +
      'punctuate=true&' +
      'interim_results=true&' +
      'endpointing=100&' +
      'vad_events=true',
      {
        headers: {
          'Authorization': `Token ${this.apiKey}`
        }
      }
    );
    
    ws.on('message', (data) => {
      const result = JSON.parse(data);
      this.handleTranscript(sessionId, result);
    });
    
    return ws;
  }
}
```

#### ElevenLabs TTS Integration
```typescript
class ElevenLabsProvider implements TTSProvider {
  async synthesize(text: string, voice: string): Promise<ReadableStream> {
    const ws = new WebSocket(
      `wss://api.elevenlabs.io/v1/text-to-speech/${voice}/stream-input?` +
      'model_id=eleven_turbo_v2_5&' +
      'output_format=pcm_16000'
    );
    
    ws.send(JSON.stringify({
      text,
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.4,
        use_speaker_boost: true
      }
    }));
    
    return this.createAudioStream(ws);
  }
}
```

### Performance Optimizations

#### Connection Pooling
```typescript
class ConnectionPool {
  private pools: Map<string, WebSocket[]> = new Map();
  
  async getConnection(provider: string): Promise<WebSocket> {
    const pool = this.pools.get(provider) || [];
    
    // Reuse existing connection
    const available = pool.find(ws => ws.readyState === WebSocket.OPEN);
    if (available) return available;
    
    // Create new connection
    const ws = await this.createConnection(provider);
    pool.push(ws);
    
    // Pre-warm connections
    if (pool.length < this.minConnections) {
      this.warmConnections(provider);
    }
    
    return ws;
  }
}
```

#### Audio Buffering
```typescript
class AudioBuffer {
  private buffer: Float32Array;
  private writeIndex: number = 0;
  private readIndex: number = 0;
  
  write(audio: Float32Array): void {
    // Ring buffer implementation
    // Handle overflow with overwrite
  }
  
  read(samples: number): Float32Array | null {
    // Non-blocking read
    // Return null if insufficient data
  }
  
  getLatency(): number {
    return (this.writeIndex - this.readIndex) / this.sampleRate * 1000;
  }
}
```

### Error Handling

```typescript
class PipelineErrorHandler {
  async handleError(error: Error, context: ErrorContext): Promise<void> {
    // Classify error
    const errorType = this.classifyError(error);
    
    switch (errorType) {
      case 'PROVIDER_ERROR':
        // Failover to backup provider
        await this.failover(context);
        break;
        
      case 'NETWORK_ERROR':
        // Retry with backoff
        await this.retryWithBackoff(context);
        break;
        
      case 'AUDIO_ERROR':
        // Request audio resend
        await this.requestResend(context);
        break;
        
      case 'RATE_LIMIT':
        // Queue and throttle
        await this.throttle(context);
        break;
        
      default:
        // Log and alert
        await this.alert(error, context);
    }
  }
}
```

### Monitoring Implementation

```typescript
class MetricsCollector {
  private metrics: Map<string, Metric[]> = new Map();
  
  recordLatency(stage: string, duration: number): void {
    this.metrics.get('latency')?.push({
      stage,
      duration,
      timestamp: Date.now()
    });
    
    // Alert if exceeds threshold
    if (duration > this.thresholds[stage]) {
      this.alert(`High latency in ${stage}: ${duration}ms`);
    }
  }
  
  async aggregate(): Promise<AggregatedMetrics> {
    return {
      latency: {
        p50: this.percentile(50, 'latency'),
        p95: this.percentile(95, 'latency'),
        p99: this.percentile(99, 'latency')
      },
      throughput: this.calculateThroughput(),
      errorRate: this.calculateErrorRate(),
      cost: this.calculateCost()
    };
  }
}
```

## Database Schema

```sql
-- Session tracking
CREATE TABLE voice_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id),
  started_at TIMESTAMP NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMP,
  duration_ms INTEGER,
  provider_costs JSONB,
  quality_score DECIMAL(3,2),
  metadata JSONB
);

-- Conversation history
CREATE TABLE voice_conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES voice_sessions(id),
  sequence_number INTEGER NOT NULL,
  speaker VARCHAR(10) NOT NULL, -- 'user' or 'assistant'
  text TEXT NOT NULL,
  audio_url TEXT,
  timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
  latency_ms INTEGER,
  confidence DECIMAL(3,2)
);

-- Provider metrics
CREATE TABLE provider_metrics (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider VARCHAR(50) NOT NULL,
  service_type VARCHAR(20) NOT NULL, -- 'stt', 'tts', 'ai'
  timestamp TIMESTAMP NOT NULL DEFAULT NOW(),
  latency_ms INTEGER NOT NULL,
  success BOOLEAN NOT NULL,
  error_message TEXT,
  cost DECIMAL(10,6)
);

-- Indexes for performance
CREATE INDEX idx_sessions_user_time ON voice_sessions(user_id, started_at DESC);
CREATE INDEX idx_conversations_session ON voice_conversations(session_id, sequence_number);
CREATE INDEX idx_metrics_provider_time ON provider_metrics(provider, timestamp DESC);
```

## Testing Strategy

### Unit Tests
```typescript
describe('AudioPipeline', () => {
  it('should detect voice activity correctly', () => {
    const silence = new Float32Array(320).fill(0);
    const voice = generateVoiceSignal();
    
    expect(pipeline.detectVoice(silence)).toBe(false);
    expect(pipeline.detectVoice(voice)).toBe(true);
  });
  
  it('should handle provider failover', async () => {
    mockDeepgram.fail();
    
    const result = await router.route(request);
    
    expect(result.provider).toBe('google');
    expect(metrics.failoverCount).toBe(1);
  });
});
```

### Integration Tests
```typescript
describe('End-to-End Pipeline', () => {
  it('should process voice in under 100ms', async () => {
    const audio = loadTestAudio('hello-world.wav');
    const start = Date.now();
    
    const response = await pipeline.process(audio);
    
    expect(Date.now() - start).toBeLessThan(100);
    expect(response.transcript).toBe('Hello world');
  });
});
```

### Load Tests
```yaml
# k6 load test configuration
scenarios:
  voice_sessions:
    executor: 'ramping-vus'
    stages:
      - duration: '2m', target: 100
      - duration: '5m', target: 1000
      - duration: '2m', target: 0
    exec: 'voiceSession'
    
thresholds:
  ws_session_duration: ['p(95)<100']
  ws_messages: ['rate>50']
  errors: ['rate<0.01']
```