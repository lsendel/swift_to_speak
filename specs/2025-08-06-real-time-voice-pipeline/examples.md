# Implementation Examples: Real-Time Voice Pipeline

## Quick Start Example

### Basic WebSocket Server (Node.js/TypeScript)

```typescript
// server/src/voice-gateway.ts
import { Server } from 'socket.io';
import { createServer } from 'http';
import { VoicePipeline } from './pipeline';
import { ProviderRouter } from './providers';

const httpServer = createServer();
const io = new Server(httpServer, {
  cors: {
    origin: ['http://localhost:3000', 'voiceflow-ai://'],
    credentials: true
  },
  transports: ['websocket'],
  pingTimeout: 60000,
  pingInterval: 25000
});

const pipeline = new VoicePipeline();
const router = new ProviderRouter();

io.on('connection', (socket) => {
  console.log(`Client connected: ${socket.id}`);
  
  let sessionId: string;
  let audioStream: AudioStream;
  
  socket.on('start-session', async (data) => {
    sessionId = await pipeline.createSession(socket.id, data.userId);
    audioStream = pipeline.getAudioStream(sessionId);
    
    socket.emit('session-started', { sessionId });
  });
  
  socket.on('audio-chunk', async (audioData: ArrayBuffer) => {
    if (!audioStream) return;
    
    // Process audio chunk
    audioStream.write(new Uint8Array(audioData));
    
    // Start processing if voice detected
    if (audioStream.hasVoice()) {
      const transcript = await router.transcribe(audioStream);
      socket.emit('transcript', { text: transcript, isFinal: false });
      
      // Generate and stream response
      const response = await router.generateResponse(transcript);
      const audioResponse = await router.synthesize(response);
      
      socket.emit('audio-response', audioResponse);
    }
  });
  
  socket.on('disconnect', () => {
    pipeline.endSession(sessionId);
  });
});

httpServer.listen(3001, () => {
  console.log('Voice gateway listening on port 3001');
});
```

### iOS Client Example (Swift)

```swift
// iOS/VoiceFlowAI/Services/VoiceService.swift
import Foundation
import AVFoundation
import SocketIO

class VoiceService: NSObject {
    private let socketManager: SocketManager
    private let socket: SocketIOClient
    private var audioEngine: AVAudioEngine
    private var inputNode: AVAudioInputNode
    private var audioBuffer: AVAudioPCMBuffer?
    
    override init() {
        let config = SocketIOClientConfiguration([
            .log(false),
            .compress,
            .secure(true),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectAttempts(-1)
        ])
        
        socketManager = SocketManager(
            socketURL: URL(string: "wss://api.voiceflow-ai.com")!,
            config: config
        )
        socket = socketManager.defaultSocket
        
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        
        super.init()
        setupSocketHandlers()
    }
    
    func startRecording() {
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        
        inputNode.installTap(
            onBus: 0,
            bufferSize: 320, // 20ms at 16kHz
            format: recordingFormat
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
        
        socket.emit("start-session", ["userId": getUserId()])
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        
        let frames = Int(buffer.frameLength)
        let data = Data(bytes: channelData[0], count: frames * 2)
        
        socket.emit("audio-chunk", data)
    }
    
    private func setupSocketHandlers() {
        socket.on("transcript") { [weak self] data, _ in
            guard let transcript = data[0] as? [String: Any],
                  let text = transcript["text"] as? String else { return }
            
            DispatchQueue.main.async {
                self?.updateTranscript(text)
            }
        }
        
        socket.on("audio-response") { [weak self] data, _ in
            guard let audioData = data[0] as? Data else { return }
            self?.playAudioResponse(audioData)
        }
    }
}
```

### Provider Router Example

```typescript
// server/src/providers/router.ts
export class ProviderRouter {
  private providers: Map<string, Provider[]> = new Map([
    ['stt', [
      new DeepgramProvider(),
      new GoogleSpeechProvider(),
      new AzureSpeechProvider()
    ]],
    ['tts', [
      new ElevenLabsProvider(),
      new AzureTTSProvider(),
      new GoogleTTSProvider()
    ]],
    ['ai', [
      new XAIProvider(),
      new OpenAIProvider()
    ]]
  ]);
  
  private healthStatus: Map<string, ProviderHealth> = new Map();
  
  async transcribe(audio: AudioStream): Promise<string> {
    const providers = this.getHealthyProviders('stt');
    
    for (const provider of providers) {
      try {
        const startTime = Date.now();
        const result = await this.withTimeout(
          provider.transcribe(audio),
          500 // 500ms timeout
        );
        
        this.recordSuccess(provider.name, Date.now() - startTime);
        return result;
        
      } catch (error) {
        this.recordFailure(provider.name, error);
        console.error(`Provider ${provider.name} failed:`, error);
        continue;
      }
    }
    
    throw new Error('All STT providers failed');
  }
  
  private getHealthyProviders(type: string): Provider[] {
    return this.providers.get(type)!
      .filter(p => {
        const health = this.healthStatus.get(p.name);
        return !health || health.failureRate < 0.1; // <10% failure rate
      })
      .sort((a, b) => {
        // Sort by latency
        const healthA = this.healthStatus.get(a.name);
        const healthB = this.healthStatus.get(b.name);
        return (healthA?.avgLatency || 0) - (healthB?.avgLatency || 0);
      });
  }
}
```

### Deepgram Integration Example

```typescript
// server/src/providers/deepgram.ts
import WebSocket from 'ws';

export class DeepgramProvider implements STTProvider {
  private ws: WebSocket | null = null;
  private apiKey: string = process.env.DEEPGRAM_API_KEY!;
  
  async connect(): Promise<void> {
    const url = 'wss://api.deepgram.com/v1/listen?' + 
      new URLSearchParams({
        model: 'nova-2',
        punctuate: 'true',
        interim_results: 'true',
        endpointing: '100',
        vad_events: 'true',
        smart_format: 'true'
      });
    
    this.ws = new WebSocket(url, {
      headers: {
        'Authorization': `Token ${this.apiKey}`
      }
    });
    
    return new Promise((resolve, reject) => {
      this.ws!.on('open', resolve);
      this.ws!.on('error', reject);
    });
  }
  
  async transcribe(audio: AudioStream): Promise<string> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      await this.connect();
    }
    
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Transcription timeout'));
      }, 5000);
      
      this.ws!.on('message', (data: string) => {
        const result = JSON.parse(data);
        
        if (result.type === 'Results') {
          const transcript = result.channel.alternatives[0].transcript;
          
          if (result.is_final) {
            clearTimeout(timeout);
            resolve(transcript);
          }
        }
      });
      
      // Send audio data
      audio.on('data', (chunk: Buffer) => {
        if (this.ws!.readyState === WebSocket.OPEN) {
          this.ws!.send(chunk);
        }
      });
    });
  }
}
```

### ElevenLabs TTS Example

```typescript
// server/src/providers/elevenlabs.ts
export class ElevenLabsProvider implements TTSProvider {
  private apiKey: string = process.env.ELEVENLABS_API_KEY!;
  private voiceId: string = 'pNInz6obpgDQGcFmaJgB'; // Adam voice
  
  async synthesize(text: string): Promise<Buffer> {
    const ws = new WebSocket(
      `wss://api.elevenlabs.io/v1/text-to-speech/${this.voiceId}/stream-input?` +
      `model_id=eleven_turbo_v2_5&output_format=pcm_16000`,
      {
        headers: {
          'xi-api-key': this.apiKey
        }
      }
    );
    
    return new Promise((resolve, reject) => {
      const audioChunks: Buffer[] = [];
      
      ws.on('open', () => {
        ws.send(JSON.stringify({
          text,
          voice_settings: {
            stability: 0.5,
            similarity_boost: 0.75,
            style: 0.4,
            use_speaker_boost: true
          },
          generation_config: {
            chunk_length_schedule: [100, 150, 200]
          }
        }));
      });
      
      ws.on('message', (data: Buffer) => {
        audioChunks.push(data);
      });
      
      ws.on('close', () => {
        resolve(Buffer.concat(audioChunks));
      });
      
      ws.on('error', reject);
    });
  }
}
```

### Voice Activity Detection Example

```typescript
// server/src/audio/vad.ts
export class VoiceActivityDetector {
  private energyThreshold: number = 0.01;
  private silenceDuration: number = 0;
  private speechDuration: number = 0;
  private isSpeaking: boolean = false;
  
  detectVoice(audioBuffer: Float32Array): boolean {
    const energy = this.calculateEnergy(audioBuffer);
    const zeroCrossings = this.calculateZeroCrossings(audioBuffer);
    
    // Simple energy-based VAD with zero-crossing rate
    const hasVoice = energy > this.energyThreshold && 
                     zeroCrossings > 10 && 
                     zeroCrossings < 100;
    
    if (hasVoice) {
      this.speechDuration += 20; // 20ms frame
      this.silenceDuration = 0;
      
      if (!this.isSpeaking && this.speechDuration > 100) {
        this.isSpeaking = true;
        this.onSpeechStart();
      }
    } else {
      this.silenceDuration += 20;
      this.speechDuration = 0;
      
      if (this.isSpeaking && this.silenceDuration > 500) {
        this.isSpeaking = false;
        this.onSpeechEnd();
      }
    }
    
    return hasVoice;
  }
  
  private calculateEnergy(buffer: Float32Array): number {
    let sum = 0;
    for (let i = 0; i < buffer.length; i++) {
      sum += buffer[i] * buffer[i];
    }
    return Math.sqrt(sum / buffer.length);
  }
  
  private calculateZeroCrossings(buffer: Float32Array): number {
    let crossings = 0;
    for (let i = 1; i < buffer.length; i++) {
      if ((buffer[i] >= 0) !== (buffer[i - 1] >= 0)) {
        crossings++;
      }
    }
    return crossings;
  }
  
  private onSpeechStart() {
    console.log('Speech started');
  }
  
  private onSpeechEnd() {
    console.log('Speech ended');
  }
}
```

### Windows Client Example (C#)

```csharp
// Windows/VoiceFlowAI/Services/VoiceService.cs
using System;
using Windows.Media.Audio;
using Windows.Media.Render;
using Microsoft.AspNetCore.SignalR.Client;

public class VoiceService
{
    private HubConnection hubConnection;
    private AudioGraph audioGraph;
    private AudioDeviceInputNode audioInput;
    private AudioFrameOutputNode frameOutput;
    
    public async Task InitializeAsync()
    {
        // Set up SignalR connection
        hubConnection = new HubConnectionBuilder()
            .WithUrl("https://api.voiceflow-ai.com/voice")
            .WithAutomaticReconnect()
            .Build();
        
        // Set up audio capture
        var settings = new AudioGraphSettings(AudioRenderCategory.Speech)
        {
            EncodingProperties = AudioEncodingProperties.CreatePcm(16000, 1, 16)
        };
        
        var result = await AudioGraph.CreateAsync(settings);
        audioGraph = result.Graph;
        
        // Create audio input
        var inputResult = await audioGraph.CreateDeviceInputNodeAsync(
            MediaCategory.Speech
        );
        audioInput = inputResult.DeviceInputNode;
        
        // Create frame output
        frameOutput = audioGraph.CreateFrameOutputNode(
            audioGraph.EncodingProperties
        );
        
        audioInput.AddOutgoingConnection(frameOutput);
        
        // Handle audio frames
        audioGraph.QuantumStarted += AudioGraph_QuantumStarted;
        
        // Set up SignalR handlers
        hubConnection.On<string>("Transcript", OnTranscript);
        hubConnection.On<byte[]>("AudioResponse", OnAudioResponse);
        
        await hubConnection.StartAsync();
    }
    
    private void AudioGraph_QuantumStarted(AudioGraph sender, object args)
    {
        var frame = frameOutput.GetFrame();
        if (frame == null) return;
        
        using (var buffer = frame.LockBuffer(AudioBufferAccessMode.Read))
        {
            var dataBuffer = Windows.Storage.Streams.Buffer.CreateCopyFromMemoryBuffer(
                buffer
            );
            
            var bytes = new byte[dataBuffer.Length];
            using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(dataBuffer))
            {
                reader.ReadBytes(bytes);
            }
            
            _ = hubConnection.SendAsync("AudioChunk", bytes);
        }
    }
    
    public async Task StartRecordingAsync()
    {
        await hubConnection.SendAsync("StartSession", GetUserId());
        audioGraph.Start();
    }
}
```

### Docker Compose Setup

```yaml
# docker-compose.yml
version: '3.8'

services:
  voice-gateway:
    build: ./server
    ports:
      - "3001:3001"
    environment:
      - NODE_ENV=development
      - REDIS_URL=redis://redis:6379
      - DATABASE_URL=postgresql://postgres:password@postgres:5432/voiceflow
      - DEEPGRAM_API_KEY=${DEEPGRAM_API_KEY}
      - ELEVENLABS_API_KEY=${ELEVENLABS_API_KEY}
      - XAI_API_KEY=${XAI_API_KEY}
    depends_on:
      - redis
      - postgres
    networks:
      - voiceflow-network
  
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    networks:
      - voiceflow-network
  
  postgres:
    image: postgres:15-alpine
    environment:
      - POSTGRES_DB=voiceflow
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - voiceflow-network
  
  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
    networks:
      - voiceflow-network
  
  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./monitoring/dashboards:/etc/grafana/provisioning/dashboards
    networks:
      - voiceflow-network

networks:
  voiceflow-network:
    driver: bridge

volumes:
  postgres-data:
```

### Environment Configuration

```bash
# .env.example
# API Keys
DEEPGRAM_API_KEY=your_deepgram_key_here
ELEVENLABS_API_KEY=your_elevenlabs_key_here
XAI_API_KEY=your_xai_key_here
GOOGLE_CLOUD_API_KEY=your_google_key_here
AZURE_SPEECH_KEY=your_azure_key_here
AWS_ACCESS_KEY_ID=your_aws_key_here
AWS_SECRET_ACCESS_KEY=your_aws_secret_here

# Database
DATABASE_URL=postgresql://postgres:password@localhost:5432/voiceflow
REDIS_URL=redis://localhost:6379

# Server Configuration
NODE_ENV=development
PORT=3001
WS_PORT=3001
LOG_LEVEL=debug

# Security
JWT_SECRET=your_jwt_secret_here
ENCRYPTION_KEY=your_encryption_key_here

# Monitoring
SENTRY_DSN=your_sentry_dsn_here
DATADOG_API_KEY=your_datadog_key_here
```

## Testing Examples

### Unit Test Example

```typescript
// server/tests/vad.test.ts
describe('VoiceActivityDetector', () => {
  let vad: VoiceActivityDetector;
  
  beforeEach(() => {
    vad = new VoiceActivityDetector();
  });
  
  it('should detect silence correctly', () => {
    const silence = new Float32Array(320).fill(0);
    expect(vad.detectVoice(silence)).toBe(false);
  });
  
  it('should detect voice correctly', () => {
    const voice = generateTestVoice(320, 440); // 440Hz tone
    expect(vad.detectVoice(voice)).toBe(true);
  });
  
  it('should handle speech transitions', () => {
    const silence = new Float32Array(320).fill(0);
    const voice = generateTestVoice(320, 440);
    
    // Start with silence
    for (let i = 0; i < 10; i++) {
      vad.detectVoice(silence);
    }
    
    // Transition to speech
    const startSpy = jest.spyOn(vad as any, 'onSpeechStart');
    for (let i = 0; i < 10; i++) {
      vad.detectVoice(voice);
    }
    expect(startSpy).toHaveBeenCalledTimes(1);
    
    // Transition back to silence
    const endSpy = jest.spyOn(vad as any, 'onSpeechEnd');
    for (let i = 0; i < 30; i++) {
      vad.detectVoice(silence);
    }
    expect(endSpy).toHaveBeenCalledTimes(1);
  });
});
```

### Load Test Example

```javascript
// tests/load-test.js
import ws from 'k6/ws';
import { check } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 100 },
    { duration: '5m', target: 1000 },
    { duration: '2m', target: 0 },
  ],
};

export default function () {
  const url = 'wss://api.voiceflow-ai.com/voice';
  const params = { tags: { name: 'VoiceSession' } };
  
  const response = ws.connect(url, params, function (socket) {
    socket.on('open', () => {
      socket.send(JSON.stringify({
        type: 'start-session',
        userId: 'test-user'
      }));
    });
    
    socket.on('message', (data) => {
      const message = JSON.parse(data);
      
      if (message.type === 'session-started') {
        // Send audio chunks
        for (let i = 0; i < 100; i++) {
          const audioChunk = new ArrayBuffer(640); // 20ms of audio
          socket.send(audioChunk);
          socket.setTimeout(() => {}, 20); // 20ms delay
        }
      }
    });
    
    socket.setTimeout(() => {
      socket.close();
    }, 10000);
  });
  
  check(response, {
    'status is 101': (r) => r && r.status === 101,
  });
}
```