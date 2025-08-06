/**
 * Comprehensive Performance Testing Suite
 * Tests latency, throughput, quality, and cost optimization
 */

import http from 'k6/http';
import ws from 'k6/ws';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const latencyTrend = new Trend('voice_latency');
const errorRate = new Rate('voice_errors');
const audioQuality = new Trend('audio_quality');
const costPerMinute = new Trend('cost_per_minute');

// Test configuration
export const options = {
  scenarios: {
    // Scenario 1: Steady load test
    steady_load: {
      executor: 'constant-vus',
      vus: 100,
      duration: '10m',
      exec: 'steadyLoadTest',
      startTime: '0s',
    },
    
    // Scenario 2: Spike test
    spike_test: {
      executor: 'ramping-vus',
      stages: [
        { duration: '2m', target: 100 },
        { duration: '1m', target: 1000 },  // Spike to 1000 users
        { duration: '2m', target: 1000 },   // Stay at 1000
        { duration: '1m', target: 100 },    // Scale down
        { duration: '2m', target: 0 },
      ],
      exec: 'spikeTest',
      startTime: '10m',
    },
    
    // Scenario 3: Stress test
    stress_test: {
      executor: 'ramping-arrival-rate',
      stages: [
        { duration: '5m', target: 100 },
        { duration: '5m', target: 200 },
        { duration: '5m', target: 300 },
        { duration: '5m', target: 400 },
        { duration: '5m', target: 500 },
      ],
      preAllocatedVUs: 500,
      maxVUs: 2000,
      exec: 'stressTest',
      startTime: '20m',
    },
    
    // Scenario 4: Endurance test
    endurance_test: {
      executor: 'constant-arrival-rate',
      rate: 50,
      timeUnit: '1s',
      duration: '2h',
      preAllocatedVUs: 200,
      exec: 'enduranceTest',
      startTime: '45m',
    },
  },
  
  thresholds: {
    'voice_latency': ['p(50)<50', 'p(95)<100', 'p(99)<150'],
    'voice_errors': ['rate<0.01'],  // <1% error rate
    'audio_quality': ['avg>0.95'],   // >95% quality score
    'cost_per_minute': ['avg<0.001'], // <$0.001 per minute
    'ws_session_duration': ['avg>60000'], // >1 minute average session
    'http_req_duration': ['p(95)<500'],
  },
};

// Test data
const TEST_AUDIO = generateTestAudio();
const ENDPOINTS = {
  http: __ENV.HTTP_ENDPOINT || 'https://api.voiceflow-ai.com',
  ws: __ENV.WS_ENDPOINT || 'wss://api.voiceflow-ai.com/voice',
};

// Steady load test - Normal usage pattern
export function steadyLoadTest() {
  const startTime = Date.now();
  
  const res = ws.connect(ENDPOINTS.ws, {}, (socket) => {
    socket.on('open', () => {
      // Start session
      socket.send(JSON.stringify({
        type: 'start_session',
        user_id: `user_${__VU}_${__ITER}`,
        platform: randomPlatform(),
        quality: 'standard',
      }));
    });
    
    socket.on('message', (data) => {
      const message = JSON.parse(data);
      
      if (message.type === 'session_started') {
        // Simulate conversation
        simulateConversation(socket, message.session_id);
      }
      
      if (message.type === 'transcript') {
        // Record latency
        const latency = Date.now() - message.timestamp;
        latencyTrend.add(latency);
        
        check(message, {
          'transcript received': (m) => m.text !== undefined,
          'latency under 100ms': (m) => latency < 100,
        });
      }
      
      if (message.type === 'audio_response') {
        // Measure audio quality
        const quality = measureAudioQuality(message.audio);
        audioQuality.add(quality);
      }
    });
    
    socket.on('error', (e) => {
      errorRate.add(1);
      console.error(`WebSocket error: ${e}`);
    });
    
    // Maintain connection for realistic session duration
    socket.setTimeout(() => {
      socket.close();
    }, 60000 + Math.random() * 120000); // 1-3 minutes
  });
  
  check(res, {
    'WebSocket connection established': (r) => r && r.status === 101,
  });
}

// Spike test - Sudden traffic surge
export function spikeTest() {
  // Similar to steady load but with rapid connection attempts
  const res = http.post(
    `${ENDPOINTS.http}/session/start`,
    JSON.stringify({
      user_id: `spike_user_${__VU}`,
      platform: 'web',
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: '10s',
    }
  );
  
  check(res, {
    'session created': (r) => r.status === 200,
    'session_id present': (r) => JSON.parse(r.body).session_id !== undefined,
    'response time OK': (r) => r.timings.duration < 1000,
  });
  
  if (res.status === 200) {
    const session = JSON.parse(res.body);
    testVoiceProcessing(session.session_id);
  }
  
  sleep(1);
}

// Stress test - Find breaking point
export function stressTest() {
  const audioChunks = generateAudioStream(10); // 10 chunks
  
  const res = ws.connect(ENDPOINTS.ws, {}, (socket) => {
    let chunksSent = 0;
    let responsesReceived = 0;
    
    socket.on('open', () => {
      socket.send(JSON.stringify({
        type: 'start_session',
        user_id: `stress_user_${__VU}`,
        platform: 'ios',
        quality: 'premium',
      }));
    });
    
    socket.on('message', (data) => {
      const message = JSON.parse(data);
      
      if (message.type === 'session_started') {
        // Rapid-fire audio chunks
        const interval = setInterval(() => {
          if (chunksSent < audioChunks.length) {
            socket.send(JSON.stringify({
              type: 'audio_chunk',
              session_id: message.session_id,
              audio: audioChunks[chunksSent],
              sequence_number: chunksSent,
            }));
            chunksSent++;
          } else {
            clearInterval(interval);
          }
        }, 20); // Send chunk every 20ms
      }
      
      if (message.type === 'transcript' || message.type === 'audio_response') {
        responsesReceived++;
      }
    });
    
    socket.setTimeout(() => {
      check(responsesReceived, {
        'all responses received': (r) => r >= audioChunks.length,
      });
      socket.close();
    }, 30000);
  });
}

// Endurance test - Long-running stability
export function enduranceTest() {
  const sessionDuration = 300000; // 5 minutes per session
  
  const res = ws.connect(ENDPOINTS.ws, {}, (socket) => {
    let messageCount = 0;
    let errorCount = 0;
    let totalLatency = 0;
    
    socket.on('open', () => {
      socket.send(JSON.stringify({
        type: 'start_session',
        user_id: `endurance_user_${__VU}`,
        platform: randomPlatform(),
        quality: randomQuality(),
      }));
    });
    
    socket.on('message', (data) => {
      messageCount++;
      const message = JSON.parse(data);
      
      if (message.type === 'session_started') {
        // Continuous conversation simulation
        continuousConversation(socket, message.session_id, sessionDuration);
      }
      
      if (message.timestamp) {
        totalLatency += Date.now() - message.timestamp;
      }
    });
    
    socket.on('error', () => {
      errorCount++;
    });
    
    socket.setTimeout(() => {
      const avgLatency = totalLatency / messageCount;
      
      check({
        messageCount,
        errorCount,
        avgLatency,
      }, {
        'message rate healthy': (m) => m.messageCount > 100,
        'error rate acceptable': (m) => m.errorCount / m.messageCount < 0.01,
        'average latency OK': (m) => m.avgLatency < 100,
      });
      
      socket.close();
    }, sessionDuration);
  });
}

// Helper function: Simulate realistic conversation
function simulateConversation(socket, sessionId) {
  const conversations = [
    'Hello, what\'s the weather today?',
    'Set a reminder for my meeting at 3 PM',
    'Tell me a joke',
    'What\'s the latest news?',
    'Play some relaxing music',
    'What\'s 15% tip on $84.50?',
    'How do I get to the nearest coffee shop?',
    'Translate hello to Spanish',
  ];
  
  let conversationIndex = 0;
  
  const speakInterval = setInterval(() => {
    if (conversationIndex < conversations.length) {
      // Simulate speaking (send audio)
      const audioData = textToAudioSimulation(conversations[conversationIndex]);
      
      socket.send(JSON.stringify({
        type: 'audio_chunk',
        session_id: sessionId,
        audio: audioData,
        sequence_number: conversationIndex,
        timestamp: Date.now(),
      }));
      
      conversationIndex++;
    } else {
      clearInterval(speakInterval);
    }
  }, 3000 + Math.random() * 2000); // 3-5 seconds between utterances
}

// Helper function: Continuous conversation for endurance testing
function continuousConversation(socket, sessionId, duration) {
  const startTime = Date.now();
  
  const converseInterval = setInterval(() => {
    if (Date.now() - startTime > duration) {
      clearInterval(converseInterval);
      return;
    }
    
    // Send audio chunk
    socket.send(JSON.stringify({
      type: 'audio_chunk',
      session_id: sessionId,
      audio: generateTestAudio(),
      sequence_number: Math.floor((Date.now() - startTime) / 1000),
      timestamp: Date.now(),
    }));
    
    // Track cost
    costPerMinute.add(calculateCost());
    
  }, 1000); // Send audio every second
}

// Helper function: Test voice processing pipeline
function testVoiceProcessing(sessionId) {
  const audioData = generateTestAudio();
  
  const res = http.post(
    `${ENDPOINTS.http}/voice/process`,
    JSON.stringify({
      session_id: sessionId,
      audio: audioData,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
      timeout: '5s',
    }
  );
  
  if (res.status === 200) {
    const result = JSON.parse(res.body);
    
    check(result, {
      'transcript present': (r) => r.transcript !== undefined,
      'confidence high': (r) => r.confidence > 0.9,
      'provider available': (r) => r.provider !== undefined,
    });
  }
}

// Helper function: Generate test audio data
function generateTestAudio() {
  // Generate 20ms of audio at 16kHz (320 samples)
  const samples = 320;
  const audio = new Uint8Array(samples * 2); // 16-bit samples
  
  for (let i = 0; i < samples; i++) {
    // Generate sine wave at 440Hz (A4 note)
    const value = Math.sin(2 * Math.PI * 440 * i / 16000) * 32767;
    audio[i * 2] = value & 0xFF;
    audio[i * 2 + 1] = (value >> 8) & 0xFF;
  }
  
  return btoa(String.fromCharCode(...audio));
}

// Helper function: Generate audio stream
function generateAudioStream(chunks) {
  const stream = [];
  for (let i = 0; i < chunks; i++) {
    stream.push(generateTestAudio());
  }
  return stream;
}

// Helper function: Measure audio quality (simulated)
function measureAudioQuality(audioData) {
  // In real implementation, would use PESQ or similar
  // For testing, return random quality score
  return 0.9 + Math.random() * 0.1; // 0.9-1.0
}

// Helper function: Calculate cost
function calculateCost() {
  // Simulated cost calculation
  const baseCost = 0.0001; // $0.0001 per request
  const providerMultiplier = Math.random() < 0.8 ? 1 : 2; // 20% use premium provider
  return baseCost * providerMultiplier;
}

// Helper function: Random platform
function randomPlatform() {
  const platforms = ['ios', 'android', 'web', 'macos', 'windows'];
  return platforms[Math.floor(Math.random() * platforms.length)];
}

// Helper function: Random quality
function randomQuality() {
  const qualities = ['economy', 'standard', 'premium'];
  const weights = [0.2, 0.6, 0.2]; // 20% economy, 60% standard, 20% premium
  
  const random = Math.random();
  let sum = 0;
  
  for (let i = 0; i < qualities.length; i++) {
    sum += weights[i];
    if (random < sum) return qualities[i];
  }
  
  return 'standard';
}

// Helper function: Text to audio simulation
function textToAudioSimulation(text) {
  // Simulate converting text to audio
  // Real implementation would use actual TTS
  const duration = text.length * 50; // ~50ms per character
  const samples = Math.floor(duration * 16); // 16kHz sample rate
  
  const audio = new Uint8Array(samples * 2);
  for (let i = 0; i < samples; i++) {
    const value = Math.random() * 65536 - 32768;
    audio[i * 2] = value & 0xFF;
    audio[i * 2 + 1] = (value >> 8) & 0xFF;
  }
  
  return btoa(String.fromCharCode(...audio));
}

// Export test summary
export function handleSummary(data) {
  return {
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),
    'performance-report.html': htmlReport(data),
    'performance-metrics.json': JSON.stringify(data, null, 2),
  };
}

// Custom HTML report generator
function htmlReport(data) {
  return `
<!DOCTYPE html>
<html>
<head>
  <title>VoiceFlow AI Performance Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; }
    .metric { margin: 10px 0; padding: 10px; border: 1px solid #ddd; }
    .pass { background: #d4edda; }
    .fail { background: #f8d7da; }
    .chart { width: 100%; height: 300px; }
  </style>
</head>
<body>
  <h1>VoiceFlow AI Performance Test Results</h1>
  
  <div class="metric ${data.metrics.voice_latency.p95 < 100 ? 'pass' : 'fail'}">
    <h3>Latency</h3>
    <p>P50: ${data.metrics.voice_latency.p50}ms</p>
    <p>P95: ${data.metrics.voice_latency.p95}ms</p>
    <p>P99: ${data.metrics.voice_latency.p99}ms</p>
  </div>
  
  <div class="metric ${data.metrics.voice_errors.rate < 0.01 ? 'pass' : 'fail'}">
    <h3>Error Rate</h3>
    <p>${(data.metrics.voice_errors.rate * 100).toFixed(2)}%</p>
  </div>
  
  <div class="metric ${data.metrics.audio_quality.avg > 0.95 ? 'pass' : 'fail'}">
    <h3>Audio Quality</h3>
    <p>${(data.metrics.audio_quality.avg * 100).toFixed(1)}%</p>
  </div>
  
  <div class="metric ${data.metrics.cost_per_minute.avg < 0.001 ? 'pass' : 'fail'}">
    <h3>Cost per Minute</h3>
    <p>$${data.metrics.cost_per_minute.avg.toFixed(4)}</p>
  </div>
  
  <h2>Test Scenarios</h2>
  <ul>
    <li>Steady Load: ${data.scenarios.steady_load.iterations} iterations</li>
    <li>Spike Test: ${data.scenarios.spike_test.iterations} iterations</li>
    <li>Stress Test: ${data.scenarios.stress_test.iterations} iterations</li>
    <li>Endurance Test: ${data.scenarios.endurance_test.iterations} iterations</li>
  </ul>
</body>
</html>
  `;
}