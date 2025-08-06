"""
VoiceFlow AI - Python FastAPI Backend
Real-time voice processing with multiple provider support
"""

import os
import asyncio
import json
from typing import Dict, List, Optional, Any
from datetime import datetime
import logging

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import uvicorn
import socketio
from pydantic import BaseModel
import numpy as np
from dotenv import load_dotenv

# Import provider services
from providers.deepgram_provider import DeepgramProvider
from providers.google_speech_provider import GoogleSpeechProvider
from providers.azure_speech_provider import AzureSpeechProvider
from providers.elevenlabs_provider import ElevenLabsProvider
from providers.azure_tts_provider import AzureTTSProvider
from providers.google_tts_provider import GoogleTTSProvider
from providers.xai_provider import XAIProvider
from providers.aws_lex_provider import AWSLexProvider

# Import audio processing
from audio.audio_processor import AudioProcessor
from audio.vad import VoiceActivityDetector
from services.pipeline_service import PipelineService
from services.session_manager import SessionManager
from services.metrics_service import MetricsService

# Load environment variables
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Initialize FastAPI app
app = FastAPI(
    title="VoiceFlow AI",
    description="Real-time voice processing pipeline",
    version="1.0.0"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize Socket.IO
sio = socketio.AsyncServer(
    async_mode='asgi',
    cors_allowed_origins='*',
    ping_timeout=60,
    ping_interval=25
)
socket_app = socketio.ASGIApp(sio, app)

# Hardware Requirements Configuration
HARDWARE_REQUIREMENTS = {
    "ios": {
        "min_version": "16.0",
        "processor": "A12 Bionic or later",
        "ram_gb": 3,
        "microphone": {
            "type": "Built-in or MFi certified",
            "sample_rate": 48000,
            "bit_depth": 16,
            "channels": 1,
            "buffer_size": 256
        },
        "audio_session": {
            "category": "AVAudioSessionCategoryPlayAndRecord",
            "mode": "AVAudioSessionModeVoiceChat",
            "options": ["AVAudioSessionOptionAllowBluetooth", "AVAudioSessionOptionDefaultToSpeaker"]
        }
    },
    "macos": {
        "min_version": "13.0",
        "processor": "M1 or Intel Core i5+",
        "ram_gb": 8,
        "microphone": {
            "type": "Core Audio compatible",
            "sample_rate": 48000,
            "bit_depth": 24,
            "channels": 1,
            "buffer_size": 512
        },
        "audio_unit": "AUHAL"
    },
    "windows": {
        "min_version": "10 build 1903",
        "processor": "Intel Core i5 or AMD Ryzen 5",
        "ram_gb": 8,
        "microphone": {
            "type": "WASAPI compatible",
            "sample_rate": 48000,
            "bit_depth": 16,
            "channels": 1,
            "buffer_size": 480
        },
        "audio_api": "WASAPI exclusive mode"
    },
    "android": {
        "min_version": "10.0",
        "processor": "Snapdragon 765 or equivalent",
        "ram_gb": 4,
        "microphone": {
            "type": "OpenSL ES or AAudio",
            "sample_rate": 48000,
            "bit_depth": 16,
            "channels": 1,
            "buffer_size": 240
        }
    }
}

# Network Requirements
NETWORK_REQUIREMENTS = {
    "bandwidth": {
        "minimum_mbps": 1.5,
        "recommended_mbps": 3.0,
        "per_stream_kbps": 256
    },
    "latency": {
        "maximum_ms": 50,
        "target_ms": 20,
        "jitter_tolerance_ms": 10
    },
    "protocols": {
        "primary": "WebSocket Secure (WSS)",
        "fallback": "HTTPS long polling",
        "audio_codec": "Opus",
        "compression": "zlib"
    },
    "ports": {
        "websocket": 443,
        "https": 443,
        "stun": 3478,
        "turn": 5349
    },
    "qos": {
        "dscp_marking": "EF (46)",
        "priority": "real-time"
    }
}

# Provider configuration
PROVIDER_CONFIG = {
    "deepgram": {
        "api_key": os.getenv("DEEPGRAM_API_KEY"),
        "model": "nova-2",
        "language": "en-US",
        "features": {
            "punctuate": True,
            "profanity_filter": False,
            "redact": [],
            "diarize": True,
            "smart_format": True,
            "interim_results": True,
            "vad_events": True,
            "endpointing": 100
        }
    },
    "google_speech": {
        "credentials": os.getenv("GOOGLE_APPLICATION_CREDENTIALS"),
        "config": {
            "encoding": "LINEAR16",
            "sample_rate_hertz": 16000,
            "language_code": "en-US",
            "enable_automatic_punctuation": True,
            "enable_word_time_offsets": True,
            "model": "latest_long",
            "use_enhanced": True
        }
    },
    "azure_speech": {
        "key": os.getenv("AZURE_SPEECH_KEY"),
        "region": os.getenv("AZURE_SPEECH_REGION", "eastus"),
        "language": "en-US",
        "format": "detailed",
        "profanity": "raw"
    },
    "elevenlabs": {
        "api_key": os.getenv("ELEVENLABS_API_KEY"),
        "voice_id": "pNInz6obpgDQGcFmaJgB",  # Adam voice
        "model_id": "eleven_turbo_v2_5",
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.75,
            "style": 0.4,
            "use_speaker_boost": True
        }
    },
    "azure_tts": {
        "key": os.getenv("AZURE_SPEECH_KEY"),
        "region": os.getenv("AZURE_SPEECH_REGION", "eastus"),
        "voice": "en-US-JennyNeural",
        "style": "cheerful",
        "style_degree": 1.5
    },
    "google_tts": {
        "credentials": os.getenv("GOOGLE_APPLICATION_CREDENTIALS"),
        "voice": {
            "language_code": "en-US",
            "name": "en-US-Studio-O",
            "ssml_gender": "FEMALE"
        },
        "audio_config": {
            "audio_encoding": "LINEAR16",
            "sample_rate_hertz": 16000,
            "speaking_rate": 1.1
        }
    },
    "xai": {
        "api_key": os.getenv("XAI_API_KEY"),
        "model": "grok-1",
        "temperature": 0.8,
        "max_tokens": 150,
        "personality": {
            "traits": ["witty", "engaging", "helpful", "upbeat"],
            "style": "conversational"
        }
    },
    "aws_lex": {
        "access_key": os.getenv("AWS_ACCESS_KEY_ID"),
        "secret_key": os.getenv("AWS_SECRET_ACCESS_KEY"),
        "region": os.getenv("AWS_REGION", "us-east-1"),
        "bot_id": "VOICEFLOW_AI",
        "bot_alias_id": "PRODUCTION"
    }
}

# Initialize services
session_manager = SessionManager()
metrics_service = MetricsService()
audio_processor = AudioProcessor()
vad = VoiceActivityDetector()

# Initialize providers
providers = {
    "stt": {
        "deepgram": DeepgramProvider(PROVIDER_CONFIG["deepgram"]),
        "google": GoogleSpeechProvider(PROVIDER_CONFIG["google_speech"]),
        "azure": AzureSpeechProvider(PROVIDER_CONFIG["azure_speech"])
    },
    "tts": {
        "elevenlabs": ElevenLabsProvider(PROVIDER_CONFIG["elevenlabs"]),
        "azure": AzureTTSProvider(PROVIDER_CONFIG["azure_tts"]),
        "google": GoogleTTSProvider(PROVIDER_CONFIG["google_tts"])
    },
    "ai": {
        "xai": XAIProvider(PROVIDER_CONFIG["xai"]),
        "lex": AWSLexProvider(PROVIDER_CONFIG["aws_lex"])
    }
}

pipeline_service = PipelineService(
    providers=providers,
    audio_processor=audio_processor,
    vad=vad,
    metrics_service=metrics_service
)

class SessionRequest(BaseModel):
    user_id: str
    platform: str
    audio_config: Optional[Dict[str, Any]] = None

class AudioChunk(BaseModel):
    session_id: str
    audio: bytes
    sequence_number: int
    timestamp: float

@app.get("/")
async def root():
    """Root endpoint with system information"""
    return {
        "name": "VoiceFlow AI",
        "version": "1.0.0",
        "status": "running",
        "providers": {
            "stt": list(providers["stt"].keys()),
            "tts": list(providers["tts"].keys()),
            "ai": list(providers["ai"].keys())
        },
        "hardware_requirements": HARDWARE_REQUIREMENTS,
        "network_requirements": NETWORK_REQUIREMENTS
    }

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    provider_health = await pipeline_service.check_provider_health()
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "providers": provider_health,
        "active_sessions": session_manager.get_active_session_count()
    }

@app.post("/session/start")
async def start_session(request: SessionRequest):
    """Start a new voice session"""
    try:
        # Validate platform requirements
        if request.platform not in HARDWARE_REQUIREMENTS:
            raise HTTPException(400, f"Unsupported platform: {request.platform}")
        
        session = await session_manager.create_session(
            user_id=request.user_id,
            platform=request.platform,
            audio_config=request.audio_config
        )
        
        # Initialize pipeline for session
        await pipeline_service.initialize_session(session.id)
        
        return {
            "session_id": session.id,
            "hardware_requirements": HARDWARE_REQUIREMENTS[request.platform],
            "network_requirements": NETWORK_REQUIREMENTS,
            "audio_config": session.audio_config
        }
    except Exception as e:
        logger.error(f"Failed to start session: {e}")
        raise HTTPException(500, str(e))

@app.websocket("/ws/voice")
async def voice_websocket(websocket: WebSocket):
    """WebSocket endpoint for real-time voice communication"""
    await websocket.accept()
    session_id = None
    
    try:
        # Wait for session initialization
        init_data = await websocket.receive_json()
        session_id = init_data.get("session_id")
        
        if not session_id:
            await websocket.send_json({
                "type": "error",
                "message": "Session ID required"
            })
            return
        
        # Validate session
        session = await session_manager.get_session(session_id)
        if not session:
            await websocket.send_json({
                "type": "error",
                "message": "Invalid session"
            })
            return
        
        # Send ready signal
        await websocket.send_json({
            "type": "ready",
            "session_id": session_id,
            "timestamp": datetime.utcnow().isoformat()
        })
        
        # Process audio stream
        while True:
            # Receive audio chunk
            data = await websocket.receive_bytes()
            
            # Process through pipeline
            result = await pipeline_service.process_audio(
                session_id=session_id,
                audio_data=data
            )
            
            # Send results back
            if result.get("transcript"):
                await websocket.send_json({
                    "type": "transcript",
                    "text": result["transcript"],
                    "is_final": result.get("is_final", False),
                    "confidence": result.get("confidence", 0.0)
                })
            
            if result.get("response_audio"):
                await websocket.send_bytes(result["response_audio"])
                await websocket.send_json({
                    "type": "response_text",
                    "text": result.get("response_text", "")
                })
                
    except WebSocketDisconnect:
        logger.info(f"WebSocket disconnected for session {session_id}")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
        await websocket.send_json({
            "type": "error",
            "message": str(e)
        })
    finally:
        if session_id:
            await session_manager.end_session(session_id)

# Socket.IO event handlers
@sio.event
async def connect(sid, environ):
    """Handle Socket.IO connection"""
    logger.info(f"Client connected: {sid}")
    await sio.emit("connected", {
        "socket_id": sid,
        "timestamp": datetime.utcnow().isoformat()
    }, to=sid)

@sio.event
async def disconnect(sid):
    """Handle Socket.IO disconnection"""
    logger.info(f"Client disconnected: {sid}")
    # Clean up session if exists
    session = await session_manager.get_session_by_socket(sid)
    if session:
        await session_manager.end_session(session.id)

@sio.event
async def start_session(sid, data):
    """Start voice session via Socket.IO"""
    try:
        session = await session_manager.create_session(
            user_id=data.get("user_id", "anonymous"),
            platform=data.get("platform", "web"),
            socket_id=sid
        )
        
        await pipeline_service.initialize_session(session.id)
        
        await sio.emit("session_started", {
            "session_id": session.id,
            "timestamp": datetime.utcnow().isoformat()
        }, to=sid)
        
    except Exception as e:
        logger.error(f"Failed to start session: {e}")
        await sio.emit("error", {
            "type": "SESSION_START_FAILED",
            "message": str(e)
        }, to=sid)

@sio.event
async def audio_chunk(sid, data):
    """Process audio chunk via Socket.IO"""
    try:
        session_id = data.get("session_id")
        audio_data = bytes(data.get("audio", []))
        
        result = await pipeline_service.process_audio(
            session_id=session_id,
            audio_data=audio_data
        )
        
        if result.get("transcript"):
            await sio.emit("transcript", {
                "text": result["transcript"],
                "is_final": result.get("is_final", False)
            }, to=sid)
        
        if result.get("response_audio"):
            await sio.emit("audio_response", {
                "audio": result["response_audio"].hex(),
                "text": result.get("response_text", "")
            }, to=sid)
            
    except Exception as e:
        logger.error(f"Failed to process audio: {e}")
        await sio.emit("error", {
            "type": "PROCESSING_FAILED",
            "message": str(e)
        }, to=sid)

if __name__ == "__main__":
    # Run the application
    uvicorn.run(
        socket_app,
        host="0.0.0.0",
        port=3001,
        log_level="info",
        access_log=True
    )