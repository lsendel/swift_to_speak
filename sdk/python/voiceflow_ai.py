"""
VoiceFlow AI Python SDK
High-performance voice processing with hardware optimization
"""

import asyncio
import json
import time
import threading
import queue
from typing import Optional, Dict, Any, Callable, List
from dataclasses import dataclass
from enum import Enum
import logging

import numpy as np
import sounddevice as sd
import websockets
import aiohttp
from websockets.client import WebSocketClientProtocol

# Optional imports for enhanced features
try:
    import torch
    TORCH_AVAILABLE = True
except ImportError:
    TORCH_AVAILABLE = False

try:
    import pyaudio
    PYAUDIO_AVAILABLE = True
except ImportError:
    PYAUDIO_AVAILABLE = False

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# Configuration classes
@dataclass
class AudioConfig:
    """Audio configuration with hardware optimization"""
    sample_rate: int = 48000  # Hardware native rate
    channels: int = 1
    dtype: str = 'int16'
    blocksize: int = 256  # Optimized for low latency
    device: Optional[str] = None
    latency: str = 'low'  # 'low', 'high', or specific value
    
    # Audio processing
    noise_suppression: bool = True
    echo_cancellation: bool = True
    auto_gain_control: bool = True
    
    # Codec settings
    codec: str = 'opus'
    bitrate: int = 64000  # 64 kbps
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            'sample_rate': self.sample_rate,
            'channels': self.channels,
            'dtype': self.dtype,
            'blocksize': self.blocksize,
            'device': self.device,
            'latency': self.latency,
            'codec': self.codec,
            'bitrate': self.bitrate
        }


@dataclass
class NetworkConfig:
    """Network configuration for optimal performance"""
    endpoint: str = "wss://api.voiceflow-ai.com/voice"
    reconnect: bool = True
    reconnect_interval: float = 1.0
    max_reconnect_attempts: int = -1  # Infinite
    ping_interval: float = 25.0
    ping_timeout: float = 60.0
    compression: str = 'deflate'
    
    # Quality of Service
    qos_level: int = 2  # 0=best effort, 1=interactive, 2=realtime
    max_latency_ms: int = 50
    jitter_buffer_ms: int = 100
    
    # Adaptive bitrate
    adaptive_bitrate: bool = True
    min_bitrate: int = 16000
    max_bitrate: int = 128000


class QualityProfile(Enum):
    """Quality profiles for different use cases"""
    PREMIUM = "premium"
    STANDARD = "standard"
    ECONOMY = "economy"
    
    def get_config(self) -> AudioConfig:
        configs = {
            QualityProfile.PREMIUM: AudioConfig(
                sample_rate=48000,
                dtype='float32',
                blocksize=128,
                latency='low',
                bitrate=128000
            ),
            QualityProfile.STANDARD: AudioConfig(
                sample_rate=24000,
                dtype='int16',
                blocksize=256,
                latency='low',
                bitrate=64000
            ),
            QualityProfile.ECONOMY: AudioConfig(
                sample_rate=16000,
                dtype='int16',
                blocksize=512,
                latency='high',
                bitrate=32000
            )
        }
        return configs[self]


class ConnectionState(Enum):
    """WebSocket connection states"""
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    RECONNECTING = "reconnecting"
    FAILED = "failed"


class VoiceFlowAI:
    """Main SDK class for VoiceFlow AI"""
    
    def __init__(
        self,
        api_key: str,
        audio_config: Optional[AudioConfig] = None,
        network_config: Optional[NetworkConfig] = None,
        quality_profile: QualityProfile = QualityProfile.STANDARD
    ):
        self.api_key = api_key
        self.audio_config = audio_config or quality_profile.get_config()
        self.network_config = network_config or NetworkConfig()
        self.quality_profile = quality_profile
        
        # State management
        self.state = ConnectionState.DISCONNECTED
        self.session_id: Optional[str] = None
        self.websocket: Optional[WebSocketClientProtocol] = None
        
        # Audio components
        self.audio_stream: Optional[sd.Stream] = None
        self.audio_queue = queue.Queue(maxsize=100)
        self.vad = VoiceActivityDetector()
        
        # Performance monitoring
        self.metrics = PerformanceMetrics()
        self.latency_monitor = LatencyMonitor()
        
        # Callbacks
        self.on_transcript: Optional[Callable] = None
        self.on_response: Optional[Callable] = None
        self.on_error: Optional[Callable] = None
        self.on_state_change: Optional[Callable] = None
        
        # Hardware detection
        self._detect_hardware()
        
        logger.info(f"VoiceFlowAI SDK initialized with {quality_profile.value} profile")
    
    def _detect_hardware(self):
        """Detect and optimize for available hardware"""
        import platform
        import psutil
        
        system_info = {
            'platform': platform.system(),
            'processor': platform.processor(),
            'cores': psutil.cpu_count(),
            'memory_gb': psutil.virtual_memory().total / (1024**3),
            'python_version': platform.python_version()
        }
        
        # Check for GPU acceleration
        if TORCH_AVAILABLE and torch.cuda.is_available():
            system_info['gpu'] = torch.cuda.get_device_name(0)
            system_info['cuda_version'] = torch.version.cuda
            logger.info(f"GPU acceleration available: {system_info['gpu']}")
        
        # Optimize based on hardware
        if system_info['cores'] >= 8 and system_info['memory_gb'] >= 16:
            logger.info("High-performance hardware detected, enabling premium features")
            self.audio_config.blocksize = 128
            self.audio_config.latency = 'low'
        elif system_info['cores'] < 4 or system_info['memory_gb'] < 8:
            logger.info("Limited hardware detected, optimizing for efficiency")
            self.audio_config.blocksize = 512
            self.audio_config.latency = 'high'
        
        self.system_info = system_info
    
    async def connect(self, user_id: Optional[str] = None) -> bool:
        """Establish WebSocket connection"""
        try:
            self.state = ConnectionState.CONNECTING
            self._notify_state_change()
            
            # Prepare connection headers
            headers = {
                'Authorization': f'Bearer {self.api_key}',
                'X-Client-Version': '1.0.0',
                'X-Platform': self.system_info['platform'],
                'X-Quality-Profile': self.quality_profile.value
            }
            
            # Connect with optimal settings
            self.websocket = await websockets.connect(
                self.network_config.endpoint,
                extra_headers=headers,
                ping_interval=self.network_config.ping_interval,
                ping_timeout=self.network_config.ping_timeout,
                compression=self.network_config.compression,
                max_size=10 * 1024 * 1024,  # 10MB max message
                max_queue=1000
            )
            
            self.state = ConnectionState.CONNECTED
            self._notify_state_change()
            
            # Start session
            await self._start_session(user_id)
            
            # Start background tasks
            asyncio.create_task(self._receive_messages())
            asyncio.create_task(self._monitor_latency())
            
            logger.info(f"Connected to VoiceFlow AI (session: {self.session_id})")
            return True
            
        except Exception as e:
            logger.error(f"Connection failed: {e}")
            self.state = ConnectionState.FAILED
            self._notify_state_change()
            
            if self.network_config.reconnect:
                asyncio.create_task(self._reconnect())
            
            return False
    
    async def _start_session(self, user_id: Optional[str] = None):
        """Initialize voice session"""
        message = {
            'type': 'start_session',
            'user_id': user_id or 'anonymous',
            'platform': self.system_info['platform'],
            'audio_config': self.audio_config.to_dict(),
            'quality_profile': self.quality_profile.value,
            'capabilities': {
                'gpu': 'gpu' in self.system_info,
                'noise_suppression': self.audio_config.noise_suppression,
                'echo_cancellation': self.audio_config.echo_cancellation
            }
        }
        
        await self.websocket.send(json.dumps(message))
        
        # Wait for session confirmation
        response = await self.websocket.recv()
        data = json.loads(response)
        
        if data.get('type') == 'session_started':
            self.session_id = data.get('session_id')
            logger.info(f"Session started: {self.session_id}")
    
    async def _receive_messages(self):
        """Background task to receive WebSocket messages"""
        try:
            async for message in self.websocket:
                data = json.loads(message) if isinstance(message, str) else message
                await self._handle_message(data)
        except websockets.ConnectionClosed:
            logger.info("WebSocket connection closed")
            self.state = ConnectionState.DISCONNECTED
            self._notify_state_change()
    
    async def _handle_message(self, data: Dict[str, Any]):
        """Process incoming messages"""
        msg_type = data.get('type')
        
        if msg_type == 'transcript':
            if self.on_transcript:
                self.on_transcript(
                    text=data.get('text'),
                    is_final=data.get('is_final', False),
                    confidence=data.get('confidence', 0.0)
                )
        
        elif msg_type == 'audio_response':
            audio_data = bytes.fromhex(data.get('audio', ''))
            if self.on_response:
                self.on_response(
                    audio=audio_data,
                    text=data.get('text', ''),
                    duration=data.get('duration', 0)
                )
            # Play audio if stream is active
            if self.audio_stream:
                await self._play_audio(audio_data)
        
        elif msg_type == 'error':
            if self.on_error:
                self.on_error(data.get('message'))
        
        elif msg_type == 'pong':
            latency = time.time() - data.get('timestamp', time.time())
            self.latency_monitor.record(latency)
    
    def start_recording(
        self,
        callback: Optional[Callable] = None,
        device: Optional[str] = None
    ):
        """Start audio recording with hardware optimization"""
        
        def audio_callback(indata, frames, time_info, status):
            """Callback for audio stream"""
            if status:
                logger.warning(f"Audio status: {status}")
            
            # Apply hardware-accelerated processing
            processed = self._process_audio(indata)
            
            # Voice activity detection
            if self.vad.is_speech(processed):
                # Add to queue for transmission
                self.audio_queue.put(processed)
                
                # User callback
                if callback:
                    callback(processed)
        
        # Configure optimal audio stream
        self.audio_stream = sd.InputStream(
            samplerate=self.audio_config.sample_rate,
            channels=self.audio_config.channels,
            dtype=self.audio_config.dtype,
            blocksize=self.audio_config.blocksize,
            device=device or self.audio_config.device,
            callback=audio_callback,
            latency=self.audio_config.latency
        )
        
        self.audio_stream.start()
        
        # Start audio transmission thread
        self.transmission_thread = threading.Thread(
            target=self._audio_transmission_loop,
            daemon=True
        )
        self.transmission_thread.start()
        
        logger.info(f"Recording started: {self.audio_config.sample_rate}Hz, "
                   f"{self.audio_config.blocksize} samples/block")
    
    def _process_audio(self, audio: np.ndarray) -> np.ndarray:
        """Apply hardware-accelerated audio processing"""
        start_time = time.perf_counter()
        
        # Convert to float for processing
        if audio.dtype != np.float32:
            audio = audio.astype(np.float32) / 32768.0
        
        # Apply filters based on configuration
        if self.audio_config.noise_suppression:
            audio = self._apply_noise_suppression(audio)
        
        if self.audio_config.echo_cancellation:
            audio = self._apply_echo_cancellation(audio)
        
        if self.audio_config.auto_gain_control:
            audio = self._apply_agc(audio)
        
        # Record processing time
        processing_time = time.perf_counter() - start_time
        self.metrics.record_processing_time(processing_time)
        
        return audio
    
    def _apply_noise_suppression(self, audio: np.ndarray) -> np.ndarray:
        """Hardware-accelerated noise suppression"""
        if TORCH_AVAILABLE and torch.cuda.is_available():
            # Use GPU for processing
            audio_tensor = torch.from_numpy(audio).cuda()
            # Apply spectral gating
            fft = torch.fft.rfft(audio_tensor)
            magnitude = torch.abs(fft)
            phase = torch.angle(fft)
            
            # Simple noise gate
            threshold = magnitude.mean() * 0.1
            magnitude[magnitude < threshold] = 0
            
            # Reconstruct
            fft_clean = magnitude * torch.exp(1j * phase)
            audio_clean = torch.fft.irfft(fft_clean)
            
            return audio_clean.cpu().numpy()
        else:
            # CPU fallback - simple noise gate
            threshold = np.mean(np.abs(audio)) * 0.1
            audio[np.abs(audio) < threshold] = 0
            return audio
    
    def _apply_echo_cancellation(self, audio: np.ndarray) -> np.ndarray:
        """Echo cancellation using adaptive filter"""
        # Simplified echo cancellation
        # In production, use speexdsp or similar
        return audio
    
    def _apply_agc(self, audio: np.ndarray) -> np.ndarray:
        """Automatic gain control"""
        target_level = 0.3
        current_level = np.sqrt(np.mean(audio**2))
        
        if current_level > 0:
            gain = target_level / current_level
            gain = np.clip(gain, 0.1, 10.0)  # Limit gain range
            audio = audio * gain
        
        return np.clip(audio, -1.0, 1.0)
    
    def _audio_transmission_loop(self):
        """Background thread for audio transmission"""
        sequence_number = 0
        
        while self.state == ConnectionState.CONNECTED:
            try:
                # Get audio from queue (with timeout)
                audio_data = self.audio_queue.get(timeout=0.1)
                
                # Compress audio
                compressed = self._compress_audio(audio_data)
                
                # Send to server
                message = {
                    'type': 'audio_chunk',
                    'session_id': self.session_id,
                    'audio': compressed.hex(),
                    'sequence_number': sequence_number,
                    'timestamp': time.time()
                }
                
                # Use asyncio to send
                asyncio.run_coroutine_threadsafe(
                    self.websocket.send(json.dumps(message)),
                    asyncio.get_event_loop()
                )
                
                sequence_number += 1
                
            except queue.Empty:
                continue
            except Exception as e:
                logger.error(f"Audio transmission error: {e}")
    
    def _compress_audio(self, audio: np.ndarray) -> bytes:
        """Compress audio using configured codec"""
        # Convert to bytes
        if audio.dtype == np.float32:
            audio = (audio * 32768).astype(np.int16)
        
        audio_bytes = audio.tobytes()
        
        # Apply compression based on codec
        if self.audio_config.codec == 'opus':
            # Would use pyopus or similar
            return audio_bytes
        else:
            return audio_bytes
    
    async def _play_audio(self, audio_data: bytes):
        """Play audio response with hardware acceleration"""
        # Convert bytes to numpy array
        audio = np.frombuffer(audio_data, dtype=np.int16)
        
        # Play using sounddevice
        sd.play(
            audio,
            samplerate=self.audio_config.sample_rate,
            device=self.audio_config.device
        )
    
    async def _monitor_latency(self):
        """Monitor connection latency"""
        while self.state == ConnectionState.CONNECTED:
            await asyncio.sleep(1)
            
            # Send ping
            message = {
                'type': 'ping',
                'timestamp': time.time()
            }
            
            try:
                await self.websocket.send(json.dumps(message))
            except Exception as e:
                logger.error(f"Ping failed: {e}")
    
    async def _reconnect(self):
        """Automatic reconnection logic"""
        attempts = 0
        
        while (self.network_config.max_reconnect_attempts == -1 or 
               attempts < self.network_config.max_reconnect_attempts):
            
            self.state = ConnectionState.RECONNECTING
            self._notify_state_change()
            
            await asyncio.sleep(self.network_config.reconnect_interval)
            
            logger.info(f"Reconnection attempt {attempts + 1}")
            
            if await self.connect():
                logger.info("Reconnected successfully")
                return
            
            attempts += 1
            # Exponential backoff
            self.network_config.reconnect_interval = min(
                self.network_config.reconnect_interval * 2,
                60  # Max 1 minute
            )
        
        logger.error("Failed to reconnect after maximum attempts")
        self.state = ConnectionState.FAILED
        self._notify_state_change()
    
    def _notify_state_change(self):
        """Notify state change callback"""
        if self.on_state_change:
            self.on_state_change(self.state)
    
    def stop_recording(self):
        """Stop audio recording"""
        if self.audio_stream:
            self.audio_stream.stop()
            self.audio_stream.close()
            self.audio_stream = None
        
        logger.info("Recording stopped")
    
    async def disconnect(self):
        """Disconnect from server"""
        self.stop_recording()
        
        if self.websocket:
            await self.websocket.close()
            self.websocket = None
        
        self.state = ConnectionState.DISCONNECTED
        self._notify_state_change()
        
        logger.info("Disconnected from VoiceFlow AI")
    
    def get_metrics(self) -> Dict[str, Any]:
        """Get performance metrics"""
        return {
            'latency': {
                'current': self.latency_monitor.get_current(),
                'p50': self.latency_monitor.get_p50(),
                'p99': self.latency_monitor.get_p99()
            },
            'processing': {
                'avg_time_ms': self.metrics.get_avg_processing_time() * 1000,
                'max_time_ms': self.metrics.get_max_processing_time() * 1000
            },
            'audio': {
                'queue_size': self.audio_queue.qsize(),
                'sample_rate': self.audio_config.sample_rate,
                'blocksize': self.audio_config.blocksize
            },
            'system': self.system_info
        }


class VoiceActivityDetector:
    """Voice Activity Detection with energy and zero-crossing rate"""
    
    def __init__(self, threshold: float = 0.01):
        self.threshold = threshold
        self.speech_frames = 0
        self.silence_frames = 0
    
    def is_speech(self, audio: np.ndarray) -> bool:
        """Detect if audio contains speech"""
        # Calculate energy
        energy = np.sqrt(np.mean(audio**2))
        
        # Calculate zero-crossing rate
        zcr = np.sum(np.diff(np.sign(audio)) != 0) / len(audio)
        
        # Simple heuristic
        is_speech = energy > self.threshold and 0.01 < zcr < 0.1
        
        if is_speech:
            self.speech_frames += 1
            self.silence_frames = 0
        else:
            self.silence_frames += 1
            if self.silence_frames > 50:  # Reset after prolonged silence
                self.speech_frames = 0
        
        return self.speech_frames > 5  # Require 5 frames of speech


class PerformanceMetrics:
    """Track performance metrics"""
    
    def __init__(self, max_samples: int = 1000):
        self.max_samples = max_samples
        self.processing_times: List[float] = []
    
    def record_processing_time(self, time: float):
        """Record audio processing time"""
        self.processing_times.append(time)
        if len(self.processing_times) > self.max_samples:
            self.processing_times.pop(0)
    
    def get_avg_processing_time(self) -> float:
        """Get average processing time"""
        if not self.processing_times:
            return 0
        return sum(self.processing_times) / len(self.processing_times)
    
    def get_max_processing_time(self) -> float:
        """Get maximum processing time"""
        return max(self.processing_times) if self.processing_times else 0


class LatencyMonitor:
    """Monitor network latency"""
    
    def __init__(self, max_samples: int = 100):
        self.max_samples = max_samples
        self.latencies: List[float] = []
    
    def record(self, latency: float):
        """Record latency measurement"""
        self.latencies.append(latency)
        if len(self.latencies) > self.max_samples:
            self.latencies.pop(0)
    
    def get_current(self) -> float:
        """Get most recent latency"""
        return self.latencies[-1] if self.latencies else 0
    
    def get_p50(self) -> float:
        """Get median latency"""
        if not self.latencies:
            return 0
        sorted_latencies = sorted(self.latencies)
        return sorted_latencies[len(sorted_latencies) // 2]
    
    def get_p99(self) -> float:
        """Get 99th percentile latency"""
        if not self.latencies:
            return 0
        sorted_latencies = sorted(self.latencies)
        index = int(len(sorted_latencies) * 0.99)
        return sorted_latencies[min(index, len(sorted_latencies) - 1)]


# Example usage
async def main():
    """Example usage of VoiceFlowAI SDK"""
    
    # Initialize SDK with API key
    sdk = VoiceFlowAI(
        api_key="your-api-key-here",
        quality_profile=QualityProfile.STANDARD
    )
    
    # Set up callbacks
    def on_transcript(text, is_final, confidence):
        print(f"Transcript: {text} (final={is_final}, conf={confidence:.2f})")
    
    def on_response(audio, text, duration):
        print(f"Response: {text} ({duration}ms)")
    
    def on_error(message):
        print(f"Error: {message}")
    
    def on_state_change(state):
        print(f"State: {state.value}")
    
    sdk.on_transcript = on_transcript
    sdk.on_response = on_response
    sdk.on_error = on_error
    sdk.on_state_change = on_state_change
    
    # Connect to server
    if await sdk.connect(user_id="test_user"):
        # Start recording
        sdk.start_recording()
        
        # Run for 30 seconds
        await asyncio.sleep(30)
        
        # Get metrics
        metrics = sdk.get_metrics()
        print(f"Metrics: {json.dumps(metrics, indent=2)}")
        
        # Disconnect
        await sdk.disconnect()


if __name__ == "__main__":
    asyncio.run(main())